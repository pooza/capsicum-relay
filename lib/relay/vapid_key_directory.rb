require 'json'
require 'net/http'
require 'uri'
require_relative 'preset_servers'
require_relative 'vapid_assertion'
require_relative 'vapid_key_ledger'

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
  # 鍵はサーバーの公開 API から取れる（2026-09-28 に 9 ホストで実測。8 つで
  # 引けた —— `st2.misskey.delmulin.com` だけ `swPublickey` が null で、
  # **ステージングの Misskey は VAPID 未設定＝そもそも push を送れない**）:
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
  #
  # ⚠ **記録と枠は [Relay::VapidKeyLedger] が持つ。**ここは「どう引くか」だけ。
  class VapidKeyDirectory
    # ⚠ **短くする。**push の受け口の中で引くので、ここで待つとキューに積むのが遅れる。
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3

    # [hosts] は引いてよいホスト（プリセット + `extra_preset_hosts`）。
    # [fetch] はテスト用の差し替え口で、`->(uri, payload) { body or nil }`。
    # payload が nil なら GET、文字列なら JSON の POST。
    def initialize(hosts:, ttl: Relay::VapidKeyLedger::DEFAULT_TTL,
      negative_ttl: Relay::VapidKeyLedger::DEFAULT_NEGATIVE_TTL,
      fetch: nil, clock: -> {Time.now.to_f})
      @hosts = Array(hosts).map {|host| Relay::PresetServers.normalize(host)}.reject(&:empty?).to_set
      @fetch = fetch || method(:http_fetch)
      @ledger = Relay::VapidKeyLedger.new(ttl: ttl, negative_ttl: negative_ttl, clock: clock)
    end

    # 引けたら base64url（パディング無し）に揃えた公開鍵。
    #
    # ⚠⚠ **戻り値は 3 通り (#69・Codex P1 6 巡目)。**
    #
    # | 戻り値 | 意味 | 呼び出し側 |
    # | --- | --- | --- |
    # | 鍵（String） | 引けた | 照合する |
    # | `nil` | **外部の障害**で引けなかった | ⚠ fail-open |
    # | [Relay::VapidKeyLedger::BUSY] | **競合**（枠が埋まっている） | ⚠⚠ **fail-open にしない**（再試行させる） |
    #
    # ⚠⚠ **競合を `nil` に畳まない。**畳むと、**同時リクエストを撃つだけで確定的に
    # ゲートを抜けられる** —— 1 本目が枠を取り、2 本目が「外部障害」として通る。
    #
    # ⚠ **枠は 2 段階。プロセス全体 → ホストごと、の順に押さえる。**順を逆に
    # すると、**全体の枠が取れなかったときにホストの枠だけ焼く**ので、引いても
    # いないのに 60 秒間そのホストが引き直せなくなる。
    def public_key_for(server)
      host = allowed(server)
      return nil unless host
      return @ledger.read(host) if @ledger.fresh?(host)
      return Relay::VapidKeyLedger::BUSY unless @ledger.acquire_slot

      begin
        # ⚠ 枠は取れたのに予約が取れない ＝ 誰かが引いている最中 / 直前に試した。
        return @ledger.throttled_outcome(host) unless @ledger.reserve(host)

        key = discover(host)
        # ⚠ 引けなければ negative cache（従来どおり）。手元の鍵は既に期限切れ。
        return @ledger.store(host, key)
      ensure
        @ledger.release_slot
      end
    end

    # ⚠⚠ **鍵が合わなかったときに 1 度だけ引き直す (#69・PR #77 の Codex P1)。**
    #
    # **プリセットサーバーが VAPID を作り直すと、TTL のあいだ手元は古い鍵のまま**に
    # なる。そのあいだ本物の push が全部 `mismatch` になり、⚠⚠ **ゲートを閉じて
    # いると 410 を返して上流の購読が永久に消える。**取り返しがつかないので、
    # 詐称と決める前に必ず引き直す。
    #
    # 戻り値は [public_key_for] と同じ 3 通り。⚠ **古い鍵をそのまま返さない**
    # （呼び出し側が**引き直した結果**と読んで詐称判定に倒す）。
    def refresh_key_for(server)
      host = allowed(server)
      return nil unless host
      # ⚠ **間隔の判定は枠の前。**I/O をしないので、枠を待たせる必要が無い。
      return @ledger.throttled_outcome(host) if @ledger.throttled?(host)
      return Relay::VapidKeyLedger::BUSY unless @ledger.acquire_slot

      begin
        return @ledger.throttled_outcome(host) unless @ledger.reserve(host)

        key = discover(host)
        # ⚠ **引けなかったら手元の記録を壊さない。**`failed` を立てるだけ。
        return @ledger.mark_failed(host) if key.nil?

        return @ledger.store(host, key)
      ensure
        @ledger.release_slot
      end
    end

    # テストと、設定を読み直したときのための口。
    def reset!
      @ledger.clear
    end

    private

    # ⚠ 一覧に無いホストは**取りに行かない**（SSRF を作らないための入口）。
    def allowed(server)
      host = Relay::PresetServers.normalize(server)
      return @hosts.include?(host) ? host : nil
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
