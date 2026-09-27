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
    # ⚠ **短くする。**push の受け口の中で引くので、ここで待つとキューに積むのが遅れる。
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3

    # [hosts] は引いてよいホスト（プリセット + `extra_preset_hosts`）。
    # [fetch] はテスト用の差し替え口で、`->(uri, payload) { body or nil }`。
    # payload が nil なら GET、文字列なら JSON の POST。
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
    def public_key_for(server)
      host = Relay::PresetServers.normalize(server)
      # ⚠ 一覧に無いホストは**取りに行かない**（SSRF を作らないための入口）。
      return nil unless @hosts.include?(host)

      cached = read_cache(host)
      return cached.first if cached

      key = discover(host)
      write_cache(host, key)
      return key
    end

    # テストと、設定を読み直したときのための口。
    def reset!
      @mon.synchronize {@cache.clear}
    end

    private

    def read_cache(host)
      return @mon.synchronize do
        entry = @cache[host]
        next nil if entry.nil?
        next nil if entry.last < @clock.call

        entry
      end
    end

    def write_cache(host, key)
      ttl = key.nil? ? @negative_ttl : @ttl
      @mon.synchronize {@cache[host] = [key, @clock.call + ttl]}
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
