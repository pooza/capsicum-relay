require 'net/http'
require 'json'
require 'uri'
require 'logger'
require_relative 'http_connection_pool'
require_relative 'sentry_setup'

module Relay
  # WNS (Windows Notification Service) raw push クライアント (capsicum#474)。
  #
  # capsicum の Windows クライアントは classic な PushNotificationChannel から
  # Channel URI を取得し device_type='windows' で登録する。relay は Mastodon /
  # Misskey から受けた RFC 8188 暗号化 push を **平文に触れないまま** WNS raw
  # 通知として Channel URI へ転送し、Windows 側のバックグラウンドタスクが
  # web_push_decrypt で復号する（APNs / FCM と同じ E2E モデル）。
  #
  # raw body は APNs custom_payload / FCM data と同一の payload ハッシュ
  # （Base64 body + encoding + server + account、build_push_payload 由来）を JSON
  # 直列化して送る。Windows bg task はこれを parse し `body` を復号する。relay は
  # 暗号文を一切復号しないため、この方式でも E2E は崩れない。
  #
  # 認証はレガシー Package SID + client secret 方式（capsicum フェーズ1 が classic
  # CreatePushNotificationChannelForApplicationAsync 系のため、Windows App SDK の
  # Azure AD wns.windows.com/.default 方式ではない）:
  #   POST https://login.live.com/accesstoken.srf
  #     grant_type=client_credentials / client_id=<Package SID>
  #     / client_secret=<secret> / scope=notify.windows.com
  # で OAuth アクセストークンを取得し、Channel URI への POST に Bearer で添える。
  # トークンは expires_in までキャッシュし、401 を受けたら 1 回だけ強制更新する。
  #
  # OAuth・トークンキャッシュ・送信・応答解釈・#21 の入力検証まで一つの WNS 送信
  # 単位に凝集しており、130 行を数行超える。分割すると I/F がまたぐだけなので、
  # App / Database と同様にここは ClassLength を inline で許容する。
  class WnsClient # rubocop:disable Metrics/ClassLength
    OAUTH_ENDPOINT = 'https://login.live.com/accesstoken.srf'.freeze
    OAUTH_SCOPE = 'notify.windows.com'.freeze
    # アクセストークン有効期限の手前で失効扱いにするマージン (秒)。
    TOKEN_EXPIRY_MARGIN = 300

    # Channel URI 自体が無効化された WNS ステータス。relay は subscription を
    # destroy し、上流（Mastodon）にも 410 を返して購読を掃除してもらう。
    #   404 Not Found : Channel URI が存在しない
    #   410 Gone      : Channel URI の有効期限切れ
    PERMANENT_STATUSES = [404, 410].freeze
    # WNS raw payload の上限 5000 バイト超過 (413)。subscription は健全なので
    # unregister せず、該当 1 通だけドロップする（APNs / FCM の oversized と同じ）。
    OVERSIZED_STATUS = 413
    # WNS raw notification の payload 上限 (バイト)。aes128gcm 暗号文を base64 化
    # したエンベロープは元 payload の約 1.4 倍に膨らみ、長い Misskey ノート等で
    # 4KB(APNs/FCM) より先に超過しうる。現状は POST して 413 を受けてから oversized
    # 処理する事後対応だが、送信前に弾いて WNS への無駄打ちと round-trip を省く
    # (#21)。倒れ方は 413 経路と同一なので観測（Sentry oversized 件数）も揃う。
    RAW_PAYLOAD_LIMIT = 5000
    # Channel URI として許可するホストの suffix。capsicum の Windows クライアント
    # が classic PushNotificationChannel から得る Channel URI は必ず
    # *.notify.windows.com に載る。device_type=windows の token は /register を
    # 通れば任意ホストへ Bearer + payload 付き POST をさせられる（SSRF）ため、
    # 送信先を WNS ホストへ限定する (#21 / capsicum#474 レビュー)。
    CHANNEL_URI_HOST_SUFFIX = '.notify.windows.com'.freeze
    # 再利用した接続が相手に閉じられていたときに飛ぶ例外 (#54)。⚠ **アイドル時間で
    # 見切っても取りこぼす**（[Relay::HttpConnectionPool#usable?] は相手の切断を
    # 知れない）ので、ここを 1 回だけ張り直して再送する。`EOFError` は `IOError`
    # の仲間なので個別に並べない。`Net::HTTPBadResponse` は切られた socket から
    # 空応答を読んだときに来る。
    STALE_CONNECTION_ERRORS = [
      IOError, Errno::ECONNRESET, Errno::EPIPE, Net::HTTPBadResponse
    ].freeze

    # Channel URI が https かつ WNS ホストであることを検査する。register の入口
    # (app.rb) と push 前 (defense-in-depth) の双方から使う class method。実 URI は
    # 必ず region 付きサブドメイン (db5p / sg2p 等) なので suffix 一致で十分、かつ
    # notify.windows.com.evil.com のような suffix なりすましは弾ける。
    def self.valid_channel_uri?(channel_uri)
      uri = URI(channel_uri.to_s)
      return false unless uri.is_a?(URI::HTTPS) && uri.host

      return uri.host.downcase.end_with?(CHANNEL_URI_HOST_SUFFIX)
    rescue URI::InvalidURIError
      return false
    end

    # 1 回の送信の結果。⚠ **接続を再利用したかを instance 変数で持たない**
    # （puma の 2 スレッド + お知らせ worker から同時に入るので、共有すると
    # 別の送信の値をログに載せる）。
    Sent = Struct.new(:response, :conn)

    # [pool] はテスト用の差し替え口。既定は Channel URI のホスト別に keep-alive
    # を持つ実物のプール (#54)。
    def initialize(config, logger: Logger.new($stdout), pool: nil)
      @config = config
      @logger = logger
      @package_sid = config['wns']['package_sid']
      @client_secret = config['wns']['client_secret']
      @token_mutex = Mutex.new
      @access_token = nil
      @token_expires_at = nil
      @pool = pool || Relay::HttpConnectionPool.new(logger: logger)
    end

    # プロセス終了時にアイドル接続を閉じる。⚠ 呼ばなくても壊れないが、
    # 呼べば FIN をこちらから送れる（相手のタイムアウト待ちにしない）。
    def close
      return @pool.close_all
    end

    def push(device_token:, payload:)
      # 送信先ホストが WNS でなければ POST しない (#21)。register で弾いているので
      # 通常は起きないが、既存行や将来の抜けに対する防御。invalid は subscription
      # を消さない（permanent: false）— 誤 unregister より観測に倒す。
      unless self.class.valid_channel_uri?(device_token)
        return invalid_channel_uri_result(device_token)
      end

      body = payload.to_json
      # 5000B 超過は POST せず 413 経路に倒す (#21)。事後の 413 と同じ oversized
      # 扱いなので上位（handle_push_oversized）の挙動・観測は変わらない。
      return oversized_precheck_result(body.bytesize) if body.bytesize > RAW_PAYLOAD_LIMIT

      sent = post_raw(device_token, body)
      # 401 はアクセストークン失効の可能性が高い。1 回だけ強制更新して再送する
      # （毎回更新すると login.live.com を過剰に叩くため、失敗起点でのみ）。
      sent = post_raw(device_token, body, force_token_refresh: true) if sent.response&.code == '401'
      return interpret(sent)
    end

    private

    # push が返す失敗ハッシュの共通形。handle_push_result が success / oversized /
    # permanent を見て分岐するので、全経路でキーを揃える。
    def failure(status:, reason:, permanent: false, oversized: false, conn: nil)
      return {
        success: false, status: status, reason: reason,
        permanent: permanent, oversized: oversized, conn: conn
      }
    end

    # 送信前 5000B 超過。interpret の 413 応答と同型 (oversized: true) を返し、
    # handle_push_oversized の drop + 観測にそのまま乗せる。
    def oversized_precheck_result(size)
      @logger.warn("WNS payload too large (pre-check): #{size} > #{RAW_PAYLOAD_LIMIT}")
      return failure(
        status: OVERSIZED_STATUS, reason: 'PayloadTooLarge (pre-check)', oversized: true,
      )
    end

    # WNS 以外のホストへ向いた Channel URI。送らずに失敗として返す。permanent:
    # false で subscription は残し、Sentry に上げて件数を観測する（想定 0 件）。
    def invalid_channel_uri_result(channel_uri)
      host = URI(channel_uri.to_s).host rescue nil
      @logger.warn("WNS channel URI rejected (non-WNS host): #{host.inspect}")
      Relay::SentrySetup.capture_message(
        'WNS channel URI rejected (non-WNS host)',
        level: :warning,
        context: {wns: {host: host}},
      )
      return failure(status: nil, reason: 'invalid_channel_uri')
    end

    def post_raw(channel_uri, body, force_token_refresh: false)
      token = access_token(force_refresh: force_token_refresh)
      return Sent.new(nil, nil) unless token

      uri = URI(channel_uri)
      return send_pooled(uri, build_request(uri, token, body))
    rescue StandardError => e
      @logger.warn("WNS push error: #{e.class}: #{e.message}")
      Relay::SentrySetup.capture_exception(e, context: {wns: {source: 'push'}})
      return Sent.new(nil, nil)
    end

    def build_request(uri, token, body)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'application/octet-stream'
      request['X-WNS-Type'] = 'wns/raw'
      request.body = body
      return request
    end

    # プールから接続を借りて 1 通送る (#54)。
    #
    # ⚠⚠ **再送してよいのは「再利用した接続が閉じられていた」ときだけ。**新規接続
    # での失敗を再送すると、相手が受理した直後に応答だけ失った場合に**二重配信**を
    # 作る。stale keep-alive は書き込み前に落ちるので、この 1 回だけは安全。
    def send_pooled(uri, request)
      http, reused = @pool.checkout(uri.hostname, uri.port)
      begin
        response = http.request(request)
        @pool.checkin(uri.hostname, uri.port, http)
        return Sent.new(response, reused ? 'reused' : 'opened')
      rescue *STALE_CONNECTION_ERRORS => e
        @pool.discard(http)
        raise unless reused

        return retry_on_fresh(uri, request, e)
      rescue StandardError
        @pool.discard(http)
        raise
      end
    end

    # 張り直して 1 回だけ送り直す。2 回目も落ちたら通常の失敗として上へ返す
    # （`post_raw` の rescue が拾って Sentry へ上げる）。
    def retry_on_fresh(uri, request, error)
      @logger.warn(
        'WNS connection was stale; reconnecting and retrying once:' \
          " #{error.class}: #{error.message}",
      )
      http, = @pool.checkout(uri.hostname, uri.port)
      begin
        response = http.request(request)
        @pool.checkin(uri.hostname, uri.port, http)
        return Sent.new(response, 'reopened')
      rescue StandardError
        @pool.discard(http)
        raise
      end
    end

    # [conn] は接続の使い回しの結末 (`reused` / `opened` / `reopened`)。⚠ push.result
    # の 1 行に載せてヒット率と latency を突き合わせるための計装 (#54)。APNs / FCM
    # は nil なので、構造化ログの compact で落ちる。
    def interpret(sent)
      response = sent.response
      return failure(status: nil, reason: 'no_response', conn: sent.conn) unless response

      status = response.code.to_i
      if response.is_a?(Net::HTTPSuccess)
        # WNS は 200 でも X-WNS-NotificationStatus が dropped / channelthrottled の
        # ことがある。配信自体は受理されたものとして success 扱いにし、観測のため
        # ステータスだけ残す。
        return {
          success: true, status: status,
          wns_status: response['X-WNS-NotificationStatus'], conn: sent.conn
        }
      end

      return failure(
        status: status,
        reason: response['X-WNS-Error-Description'] || response['X-WNS-Status'] || response.message,
        permanent: PERMANENT_STATUSES.include?(status),
        oversized: status == OVERSIZED_STATUS,
        conn: sent.conn,
      )
    end

    def access_token(force_refresh: false)
      @token_mutex.synchronize do
        return @access_token if !force_refresh && token_valid?

        return fetch_access_token!
      end
    end

    def token_valid?
      return false if @access_token.nil? || @token_expires_at.nil?

      return Time.now < @token_expires_at
    end

    def fetch_access_token!
      response = request_oauth_token
      unless response.is_a?(Net::HTTPSuccess)
        @logger.error("WNS OAuth failed: #{response&.code}")
        Relay::SentrySetup.capture_message(
          'WNS OAuth token fetch failed',
          level: :error,
          context: {wns: {status: response&.code}},
        )
        return reset_token!
      end
      return store_token!(JSON.parse(response.body))
    rescue StandardError => e
      @logger.error("WNS OAuth error: #{e.class}: #{e.message}")
      Relay::SentrySetup.capture_exception(e, context: {wns: {source: 'oauth'}})
      return reset_token!
    end

    def request_oauth_token
      uri = URI(OAUTH_ENDPOINT)
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(
        'grant_type' => 'client_credentials',
        'client_id' => @package_sid,
        'client_secret' => @client_secret,
        'scope' => OAUTH_SCOPE,
      )
      return Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end
    end

    def store_token!(body)
      @access_token = body['access_token']
      expires_in = body.fetch('expires_in', 86_400).to_i
      @token_expires_at = Time.now + [expires_in - TOKEN_EXPIRY_MARGIN, 0].max
      return @access_token
    end

    def reset_token!
      @access_token = nil
      @token_expires_at = nil
      return nil
    end
  end
end
