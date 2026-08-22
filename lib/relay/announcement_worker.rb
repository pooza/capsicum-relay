require 'json'
require 'net/http'
require 'uri'
require_relative 'announcement_delivery_reporter'
require_relative 'sentry_setup'

module Relay
  # お知らせ通知 (announcement push) の polling worker。capsicum-relay#14 Phase 2。
  #
  # announcement_subscriptions に登録された server を一定間隔で polling し、
  # 未送信の announcement を seen_announcements で dedup して APNs / FCM に
  # 配信する。取得は各サーバーのモロヘイヤ公開キャッシュ
  # `/mulukhiya/api/announcement/list` 経由（SNS の announcement API は認証
  # 必須なため relay から直接は叩けない）。Mastodon / Misskey 両対応で、
  # normalize_announcement が published_at / createdAt の差分を吸収する。
  # 各サーバーの mulukhiya が features.announcement_push: true (5.24.0+) で有効。
  #
  # ⚠ ClassLength を inline で許容している。#36 Phase 2 で 4 つ目の配送先
  # (WNS) が入り、.rubocop.yml の 130 行（クライアント系クラスの実態に合わせた
  # 上限）を数行超えた。polling → 正規化 → payload 組み立て → 配送は 1 つの
  # 凝集した単位で、切るなら ApnsClient / ApnsPayload と同じ「payload の seam」
  # だが、それは Phase 2 の範囲外。共有の上限を全クラスぶん緩めるより、
  # .rubocop.yml が明記している「超えるクラスは個別に inline disable」に倣う。
  class AnnouncementWorker # rubocop:disable Metrics/ClassLength
    DEFAULT_INTERVAL = 60
    REQUEST_TIMEOUT = 10
    # register が受け付ける device_type (#36 で 4 種そろった)。配送できなかった
    # ときの理由分けに使う。
    KNOWN_DEVICE_TYPES = ['ios', 'macos', 'android', 'windows'].freeze

    # ⚠ ParameterLists を inline で許容している。6 つすべて**キーワード引数**で、
    # このコップが狙う「順序を覚えられない位置引数の列」にはあたらない。増えたのは
    # push クライアントが 4 種そろったためで、束ねると base_app 側の
    # `settings.respond_to?` の分岐が別の入れ物へ移るだけになる。
    # rubocop:disable Metrics/ParameterLists
    def initialize(
      database:, logger:, apns: nil, fcm: nil, wns: nil, metrics: nil,
      interval: DEFAULT_INTERVAL
    )
      @database = database
      @logger = logger
      @apns = apns
      @fcm = fcm
      @wns = wns
      @interval = interval
      @stop = false
      # 配送 1 通ごとの結末を観測に落とす (#44)。
      @reporter = Relay::AnnouncementDeliveryReporter.new(
        logger: logger, metrics: metrics, database: database,
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # Sinatra の settings から push クライアントを拾って組み立てる (#36 Phase 2)。
    #
    # ⚠ **「どのクライアントを渡すか」を `deliver` の case と同じファイルに置く**
    # のが目的。base_app 側に配線を散らしていたときは、`deliver` に `windows` を
    # 足しても渡し忘れれば「購読行はあるのに 1 通も届かない」形になり、しかも
    # 例外にならないので**テストにもログにも出なかった**（実測で確認した）。
    # ここに寄せたので、下の from_settings のテストが 4 種すべての導通を見る。
    #
    # 各クライアントは config に鍵が無ければ `set` されない（base_app 参照）ので、
    # respond_to? で存在を確かめてから渡す。未設定なら nil のまま = その device_type
    # へは送らない。
    def self.from_settings(settings, database:, logger:, interval: DEFAULT_INTERVAL)
      return new(
        database: database,
        logger: logger,
        interval: interval,
        apns: (settings.respond_to?(:apns) ? settings.apns : nil),
        fcm: (settings.respond_to?(:fcm) ? settings.fcm : nil),
        wns: (settings.respond_to?(:wns) ? settings.wns : nil),
        # `/metrics` の counter (#2)。App と同じインスタンスを渡す — worker は
        # 同一プロセスの別スレッドなので、Metrics の Monitor でそのまま共有できる
        # （workers 0 前提。Metrics のコメント参照）。
        metrics: (settings.respond_to?(:metrics) ? settings.metrics : nil),
      )
    end

    def start!
      @thread = Thread.new do
        Thread.current.name = 'announcement_worker'
        run_loop
      end
      @thread.report_on_exception = true
    end

    def stop!
      @stop = true
      @thread&.wakeup if @thread&.alive?
    end

    def poll_once
      @database.announcement_servers.each do |server|
        poll_server(server)
      end
    rescue StandardError => e
      report_error('poll_once', e)
    end

    private

    def run_loop
      until @stop
        begin
          poll_once
        rescue StandardError => e
          report_error('run_loop', e)
        end
        sleep @interval
      end
    end

    def poll_server(server)
      announcements = fetch_announcements(server)
      announcements.each do |announcement|
        id = announcement['id'].to_s
        next if id.empty?
        next if @database.announcement_seen?(server, id)

        dispatch_push(server, announcement)
        # ⚠ **配送の成否に関わらず seen を打つ**（#44 で観測を入れた後も現状維持）。
        # `mark_announcement_seen` は **server 単位で購読単位ではない**ので、
        # 「失敗したら打たない」にすると 1 台の失敗でそのサーバーの購読者全員へ
        # 再送になる。購読単位の配送状態を持つ改修（#44 の A 案 / B 案）は移行を
        # 伴うため、まず `relay_announcement_push_total` で実際の失敗率を見てから
        # 選ぶ。**今は「失われた 1 通が数字とログに残る」ところまで。**
        @database.mark_announcement_seen(server, id)
      end
    rescue StandardError => e
      report_error("poll_server(#{server})", e)
    end

    # モロヘイヤの公開キャッシュ endpoint (mulukhiya-toot-proxy#4355) を polling。
    # SNS の announcement API は認証必須なため capsicum-relay からは叩けず、モロ
    # ヘイヤが既に info_agent_service で fetch + Redis キャッシュ済みのデータを
    # 経由する。features.announcement_push: true を返す mulukhiya 5.24.0+ で有効。
    # Mastodon / Misskey 両方とも `id` / `content` フィールドを持つため、正規化は
    # published_at (Mastodon) / createdAt (Misskey) の差分吸収だけで済む。
    def fetch_announcements(server)
      uri = URI("https://#{server}/mulukhiya/api/announcement/list")
      response = Net::HTTP.start(uri.hostname, uri.port,
        use_ssl: true,
        open_timeout: REQUEST_TIMEOUT,
        read_timeout: REQUEST_TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      return [] unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      return [] unless parsed.is_a?(Array)
      return parsed.map {|item| normalize_announcement(item)}
    rescue StandardError => e
      @logger.warn(
        "fetch_announcements(#{server}) failed: #{e.class}: #{e.message}",
      )
      return []
    end

    # モロヘイヤ /announcement/list は Mastodon は content + published_at、
    # Misskey は content + createdAt の shape で返す。downstream で扱いやすい
    # 統一 shape に揃える。
    def normalize_announcement(item)
      return {
        'id' => item['id'],
        'content' => item['content'].to_s,
        'published_at' => (item['published_at'] || item['createdAt']).to_s,
      }
    end

    def dispatch_push(server, announcement)
      subs = @database.announcement_subscriptions_for_server(server)
      id = announcement['id'].to_s
      # ⚠ **空でも先に 1 行出す。** 「そもそも購読が無い」と「送ったが失敗した」を
      # journald だけで切り分けられるようにするため (#44 の 2026-08-18 コメント)。
      @reporter.record_dispatch(server: server, announcement_id: id, subs: subs)
      return if subs.empty?

      payload = build_payload(server, announcement)
      alert = build_alert(announcement)
      subs.each do |sub|
        deliver(sub: sub, payload: payload, alert: alert, server: server, announcement_id: id)
      end
    end

    # お知らせ 1 通を 1 購読へ配送する。宛先の選択は [client_for]、payload の
    # 変形は [push_to]（どちらも分岐は通常の push 経路と同じ形に揃える・#36）。
    #
    # ⚠ **戻り値を捨てない** (#44)。従来はここで push した結果を見ておらず、
    # 失敗しても journald にも `/metrics` にも Sentry にも何も残らなかった。
    # `poll_server` は dispatch 後に無条件で `mark_announcement_seen` を打つので
    # 再送も起きず、**「お知らせが届かない」の手掛かりが relay 側に無かった**。
    # 結末の解釈と観測は [Relay::AnnouncementDeliveryReporter] に寄せてある
    # （seen の粒度はこの Issue では変えない。理由は同クラスのコメント）。
    def deliver(sub:, payload:, alert:, server: nil, announcement_id: nil)
      client = client_for(sub['device_type'])
      unless client
        return @reporter.record_unconfigured(
          sub: sub, server: server, announcement_id: announcement_id,
          reason: unavailable_reason(sub['device_type'])
        )
      end

      result = push_to(client, sub, payload.merge('account' => sub['account']), alert)
      return @reporter.record(
        sub: sub, server: server, announcement_id: announcement_id, result: result,
      )
    rescue StandardError => e
      return @reporter.record_exception(
        sub: sub, server: server, announcement_id: announcement_id, error: e,
      )
    end

    # device_type ごとの送信クライアント。未設定・未知の device_type なら nil。
    # 分岐は通常の push 経路 ([Relay::PushHelpers#push_client_for]) と**同じ形に
    # 揃える**（#36）。
    #
    # `macos` は iOS と同一 Bundle ID・同一 APNs Auth Key で送れるので、同じ
    # クライアントに流すだけでよい (capsicum#468)。**capsicum 側の変更は不要**:
    # iOS/macOS の Notification Service Extension は `body` / `encoding` を
    # 持たない push を早期 guard で素通しし、[push_to] が付ける `aps.alert` が
    # そのまま表示される（#17 で実測済みの挙動）。
    def client_for(device_type)
      case device_type
      when 'ios', 'macos' then @apns
      when 'android' then @fcm
      when 'windows' then @wns
      end
    end

    # 送れなかった理由を「設定漏れ」と「未知の device_type」で分ける。前者は
    # 直せる不具合（base_app の配線漏れ・鍵の入れ忘れ）、後者は register 側が
    # 受け付ける種別が増えたのに配送が追いついていない印。
    def unavailable_reason(device_type)
      return KNOWN_DEVICE_TYPES.include?(device_type) ? 'client_unset' : 'unknown_device_type'
    end

    # payload の変形は device_type ごとに違う（windows だけ別。下の wns_payload）。
    #
    # `windows` は WNS raw push（Phase 2 / capsicum#978）。`aps.alert` に相当する
    # OS 側の表示機構が無いので、トーストは capsicum の bg task が
    # `announcement_body` から自分で組む。**alert は渡さない** — 使われない大きな
    # 引数になるだけ。FCM data も同様。
    def push_to(client, sub, enriched, alert)
      case sub['device_type']
      when 'ios', 'macos'
        return client.push(device_token: sub['token'], payload: enriched, alert: alert)
      when 'android'
        return client.push(device_token: sub['token'], payload: enriched)
      when 'windows'
        return client.push(device_token: sub['token'], payload: wns_payload(enriched))
      end
    end

    # Windows 宛だけの payload 変形 (#36 Phase 2 / capsicum#978)。
    #
    # **`announcement_body` を足す。** WNS raw push には `aps.alert` に相当する
    # OS 側の表示機構が無く、トーストは capsicum の bg task が自分で組む。
    # `announcement_content` は HTML のままなので、整形済みの本文をここで渡さないと
    # C++/WinRT 側に HTML 剥がしと UTF-8 の文字数え（バイトで切ると日本語が壊れる）を
    # **3 つ目の実装として**書くことになる（Ruby の summarize_content / Dart の
    # PushMessageDispatcher.synthesizeAnnouncementBody に続いて）。
    #
    # **`announcement_content` は落とす。** Windows が読むのは `account` /
    # `announcement_body` / `announcement_id` だけで、HTML は 1 バイトも使わない
    # （capsicum `web_push_receive.cpp` の TryBuildAnnouncementDisplay）。WNS raw の
    # 上限 5000 バイトを超えると [Relay::WnsClient] の送信前チェックが 1 通まるごと
    # 落とすので、載せたままだと「表示に使わないデータのせいで通知そのものが消える」。
    # 落とせば残るのは 80 文字の本文とメタだけで、長文のお知らせでも上限に近づかない。
    #
    # ⚠ **どちらの変形も windows 宛に閉じている**（Codex P1 / PR #43）。
    # - content を落とすのは windows だけ。iOS / macOS / Android は capsicum が
    #   そこからフル HTML をレンダリングする経路 (#477) を持っており、落とすと壊れる。
    # - body を足すのも windows だけ。全 device_type に足すと、4KB 上限に近い
    #   お知らせが APNs / FCM で**新たに**上限超えになりうる。しかも
    #   `ApnsPayload#degraded_payload` が落とすのは暗号化 Web Push 由来のキーだけ
    #   なので degrade で救えず、`poll_server` は dispatch 後に
    #   `mark_announcement_seen` を打つため**再送もされない**（その 1 通が永久に
    #   失われる）。他の 3 種の payload は Phase 2 の前後でバイト単位で不変にする。
    def wns_payload(payload)
      return payload
          .except('announcement_content')
          .merge('announcement_body' => summarize_content(payload['announcement_content'].to_s))
    end

    # APNs custom_payload / FCM data は capsicum 側で notification_type を見て
    # NotificationType.announcement に routing される (#477)。FCM の data は
    # transform_values(&:to_s) されるため flat な文字列値で構成する。
    #
    # ⚠ **ここは全 device_type 共通の最小形に保つ。** Windows 用の
    # `announcement_body` は [wns_payload] が配送時に足す。ここに足すと 4KB 上限に
    # 近いお知らせが APNs / FCM で新たに上限超えになりうるうえ、degrade でも救えず
    # 再送もされない（Codex P1 / PR #43。詳細は wns_payload のコメント）。
    def build_payload(server, announcement)
      {
        'notification_type' => 'announcement',
        'server' => server,
        'announcement_id' => announcement['id'].to_s,
        'announcement_content' => announcement['content'].to_s,
        'announcement_published_at' => announcement['published_at'].to_s,
      }
    end

    def build_alert(announcement)
      {
        title: 'お知らせ',
        body: summarize_content(announcement['content'].to_s),
      }
    end

    # HTML タグを大雑把に剥がしてプレビュー長に切る。詳細表示は capsicum 側で
    # フルレンダリング。
    def summarize_content(html, max: 80)
      plain = html.gsub(/<[^>]+>/, '').gsub(/\s+/, ' ').strip
      return plain.length > max ? "#{plain[0, max]}…" : plain
    end

    def report_error(context, error)
      @logger.error(
        "AnnouncementWorker[#{context}]: #{error.class}: #{error.message}",
      )
      Relay::SentrySetup.capture_exception(
        error, context: {announcement_worker: {context: context}}
      )
    end
  end
end
