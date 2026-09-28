require 'json'
require 'monitor'
require 'net/http'
require 'uri'
require_relative 'preset_servers'
require_relative 'vapid_assertion'

module Relay
  # プリセットサーバーの VAPID 公開鍵を引いて覚えておく (#69)。
  #
  # ⚠⚠ **引くのは許可した一覧のホストだけ。**`subscription['server']` は
  # **クライアントの申告**なので、それをそのまま取りに行くと **relay が任意の
  # ホストへ HTTP を投げる道具になる**（SSRF）。⚠ **申告は「一覧のどれを名乗って
  # いるか」を選ぶためにしか使わない。**
  #
  # ⚠ **鍵は自動で追随させる。**9 ホストぶんを設定ファイルへ手で貼ると、
  # [Relay::PresetServers] の一覧と同じ「2 か所に同じものがある」形が増える。
  # 鍵はサーバーの公開 API から取れる（2026-09-28 に 4 サーバーで実測）:
  #
  # | | エンドポイント | 場所 |
  # | --- | --- | --- |
  # | Mastodon | `GET /api/v2/instance` | `configuration.vapid.public_key` |
  # | Misskey | `POST /api/meta` | `swPublickey` |
  #
  # ⚠ **どちらのソフトかは持っていない**ので、Mastodon → Misskey の順に試す。
  #
  # ⚠⚠ **引けなかったことと「鍵が違う」ことを混ぜない。**引けないのは**こちらの
  # 障害**で、そのときゲートは fail-open で通す（[Relay::EntitlementGate]）。
  # ここは **nil を返すだけ**で、倒し方は呼び出し側が決める。
  class VapidKeyDirectory
    # 引き直す間隔。⚠ **鍵の更新は滅多に起きない**（サーバーの VAPID を作り直した
    # ときだけ）ので長くてよい。⚠ **短くすると push 1 通ごとの外向き HTTP が増える。**
    DEFAULT_TTL = 6 * 60 * 60
    # 引けなかったときに次に試すまで。⚠ **落ちているサーバーを叩き続けない。**
    DEFAULT_NEGATIVE_TTL = 10 * 60
    # [refresh_key_for] を続けて呼ばれたときに、実際に引き直す最短間隔。
    #
    # ⚠⚠ **これが無いと DoS の踏み台になる。**引き直しは「鍵が合わない push が
    # 来た」ときに走るので、**合わない鍵で叩き続けるだけでプリセットサーバーへ
    # 好きなだけ HTTP を出させられる。**
    MIN_REFRESH_INTERVAL = 60
    # 記録は `[鍵, 期限, 引き直しを試みた時刻, その試みが失敗したか]`。
    #
    # ⚠ **4 つ目は「引き直し」だけのための印。**[public_key_for] の経路は見ない
    # （手元の鍵は期限まで有効で、引き直しの成否とは別の話）。
    KEY = 0
    EXPIRES_AT = 1
    ATTEMPTED_AT = 2
    FAILED = 3
    private_constant :KEY, :EXPIRES_AT, :ATTEMPTED_AT, :FAILED

    # ⚠ **短くする。**push の受け口の中で引くので、ここで待つとキューに積むのが遅れる。
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3

    # [hosts] は引いてよいホスト（プリセット + `extra_preset_hosts`）。
    # [fetch] はテスト用の差し替え口で、`->(uri, payload) { body or nil }`。
    # payload が nil なら GET、文字列なら JSON の POST。
    # ⚠ [MIN_REFRESH_INTERVAL] は注入できるようにしていない。テストは [clock] を
    # 進めれば足りるし、**運用で緩める値ではない**（緩めると DoS の踏み台になる）。
    def initialize(hosts:, ttl: DEFAULT_TTL, negative_ttl: DEFAULT_NEGATIVE_TTL,
      fetch: nil, clock: -> {Time.now.to_f})
      @hosts = Array(hosts).map {|host| Relay::PresetServers.normalize(host)}.reject(&:empty?).to_set
      @ttl = ttl
      @negative_ttl = negative_ttl
      @fetch = fetch || method(:http_fetch)
      @clock = clock
      @cache = {}
      @mon = Monitor.new
    end

    # 引けたら base64url（パディング無し）に揃えた公開鍵、引けなければ nil。
    #
    # ⚠⚠ **ここも I/O の前に枠を押さえる (#69・PR #77 の Codex P1 4 巡目)。**
    # 単発化を [refresh_key_for] にしか入れていなかったので、**起動直後や
    # 期限切れの瞬間に来た同時要求が全部 `discover` に入れた** —— 相手が落ちて
    # いると、**puma のスレッドが揃って timeout を待つ**形が残っていた。
    #
    # ⚠ **枠が取れなければ nil**（誰かが引いている最中 / 直前に試して失敗した）。
    # 呼び出し側は fail-open に倒す。
    def public_key_for(server)
      host = allowed(server)
      return nil unless host

      cached = read_cache(host)
      return cached[KEY] if cached
      return nil unless reserve_fetch(host)

      # ⚠ 引けなければ negative cache（従来どおり）。手元の鍵は既に期限切れ。
      return store(host, discover(host))
    end

    # ⚠⚠ **鍵が合わなかったときに 1 度だけ引き直す (#69・PR #77 の Codex P1)。**
    #
    # **プリセットサーバーが VAPID を作り直すと、TTL のあいだ手元は古い鍵のまま**に
    # なる。そのあいだ本物の push が全部 `mismatch` になり、⚠⚠ **ゲートを閉じて
    # いると 410 を返して上流の購読が永久に消える。**取り返しがつかないので、
    # 詐称と決める前に必ず引き直す。
    #
    # 戻り値は **引き直せた鍵**。⚠ **引き直せなかったら nil**（呼び出し側は
    # fail-open に倒す）—— 古い鍵をそのまま返すと、⚠ **上の事故がそのまま起きる。**
    #
    # ⚠ **[MIN_REFRESH_INTERVAL] のあいだは引き直さず、直前の結果を返す。**
    #
    # ⚠⚠ **直前が失敗なら、間隔のあいだは nil を返し続ける (#69・Codex P1 3 巡目)。**
    # 手元の古い鍵を返すと、呼び出し側がそれを**引き直した結果**と読んで
    # `mismatch` に倒し、**410 で購読が消える** —— 障害中に fail-open になるのは
    # 最初の 1 通だけ、という形になっていた。
    #
    # ⚠⚠ **枠は I/O の前に押さえる (#69・Codex P1 3 巡目)。**押さえる前に
    # `discover` を走らせていたので、**間隔が明けた直後に来た同時要求が全部
    # 素通りして、puma のスレッドぶん一斉に外向き HTTP を出していた。**
    # 1 ホストあたり 60 秒に 1 本、を**並行でも**守る。
    def refresh_key_for(server)
      host = allowed(server)
      return nil unless host
      return throttled_result(host) unless reserve_fetch(host)

      key = discover(host)
      # ⚠ **引けなかったら手元の記録を壊さない。**negative cache で上書きすると、
      # 一時的な通信障害のあとに「鍵が無い」状態が居座る。⚠ 予約の時点で
      # 「失敗」を立ててあるので、間隔が明けるまでは nil が返る。
      return nil if key.nil?

      return store(host, key)
    end

    # テストと、設定を読み直したときのための口。
    def reset!
      @mon.synchronize {@cache.clear}
    end

    private

    # ⚠ 一覧に無いホストは**取りに行かない**（SSRF を作らないための入口）。
    def allowed(server)
      host = Relay::PresetServers.normalize(server)
      return @hosts.include?(host) ? host : nil
    end

    def read_cache(host)
      return @mon.synchronize do
        entry = @cache[host]
        next nil if entry.nil?
        next nil if entry[EXPIRES_AT] < @clock.call

        entry
      end
    end

    # ⚠⚠ **I/O の前に枠を押さえる。**チェックと更新を 1 つの critical section に
    # 入れないと、**間隔が明けた直後の同時要求が全部素通りする**（Codex P1 3 巡目）。
    #
    # ⚠ **悲観的に「失敗」を立ててから出ていく。**引いている最中に来た要求には
    # nil を返したい（＝ fail-open）ので、成功したときに [store] が倒す。
    def reserve_fetch(host)
      now = @clock.call
      return @mon.synchronize do
        entry = @cache[host]
        next false if entry && (now - entry[ATTEMPTED_AT]) < MIN_REFRESH_INTERVAL

        @cache[host] = if entry.nil?
          [nil, now + @negative_ttl, now, true]
        else
          [entry[KEY], entry[EXPIRES_AT], now, true]
        end
        true
      end
    end

    # 間隔のあいだに来た要求への答え。
    #
    # ⚠⚠ **直前の試みが失敗（または進行中）なら nil。**手元の古い鍵を返すと、
    # 呼び出し側が**引き直した結果**と読んで詐称判定に倒し、410 で購読が消える。
    def throttled_result(host)
      return @mon.synchronize do
        entry = @cache[host]
        next nil if entry.nil?
        next nil if entry[FAILED]

        entry[KEY]
      end
    end

    def store(host, key)
      ttl = key.nil? ? @negative_ttl : @ttl
      now = @clock.call
      @mon.synchronize {@cache[host] = [key, now + ttl, now, false]}
      return key
    end

    # ⚠ **Mastodon → Misskey の順に試す。**どちらでもなければ nil。
    def discover(host)
      return mastodon_key(host) || misskey_key(host)
    end

    def mastodon_key(host)
      body = call("https://#{host}/api/v2/instance", nil)
      return normalize(parse(body)&.dig('configuration', 'vapid', 'public_key'))
    end

    def misskey_key(host)
      body = call("https://#{host}/api/meta", '{"detail":false}')
      return normalize(parse(body)&.[]('swPublickey'))
    end

    # ⚠ **何が起きても nil。**外向きの HTTP は落ちる前提で、push の受け口を
    # 巻き込まない。「引けなかった」は呼び出し側が metrics に出す。
    def call(url, payload)
      return @fetch.call(URI.parse(url), payload)
    rescue StandardError
      return nil
    end

    def parse(body)
      return nil if body.nil?

      json = JSON.parse(body)
      return json.is_a?(Hash) ? json : nil
    rescue JSON::ParserError
      return nil
    end

    # ⚠ ヘッダ側と同じ形へ揃えてから覚える（[Relay::VapidAssertion.normalize_key]）。
    def normalize(value)
      key = value.to_s.strip
      return nil if key.empty?

      return Relay::VapidAssertion.normalize_key(key)
    end

    # ⚠ **リダイレクトを追わない。**追うと一覧の外のホストへ出て行けてしまう。
    def http_fetch(uri, payload)
      request = build_request(uri, payload)
      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
      ) {|http| http.request(request)}
      return response.is_a?(Net::HTTPSuccess) ? response.body : nil
    end

    def build_request(uri, payload)
      return Net::HTTP::Get.new(uri) if payload.nil?

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request.body = payload
      return request
    end
  end
end
