require 'net/http'
require 'json'
require 'uri'
require 'logger'
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
  class WnsClient
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

    def initialize(config, logger: Logger.new($stdout))
      @config = config
      @logger = logger
      @package_sid = config['wns']['package_sid']
      @client_secret = config['wns']['client_secret']
      @token_mutex = Mutex.new
      @access_token = nil
      @token_expires_at = nil
    end

    def push(device_token:, payload:)
      body = payload.to_json
      response = post_raw(device_token, body)
      # 401 はアクセストークン失効の可能性が高い。1 回だけ強制更新して再送する
      # （毎回更新すると login.live.com を過剰に叩くため、失敗起点でのみ）。
      response = post_raw(device_token, body, force_token_refresh: true) if response&.code == '401'
      return interpret(response)
    end

    private

    def post_raw(channel_uri, body, force_token_refresh: false)
      token = access_token(force_refresh: force_token_refresh)
      return nil unless token

      uri = URI(channel_uri)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'application/octet-stream'
      request['X-WNS-Type'] = 'wns/raw'
      request.body = body
      return Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end
    rescue StandardError => e
      @logger.warn("WNS push error: #{e.class}: #{e.message}")
      Relay::SentrySetup.capture_exception(e, context: {wns: {source: 'push'}})
      return nil
    end

    def interpret(response)
      unless response
        return {
          success: false, status: nil, reason: 'no_response', permanent: false, oversized: false
        }
      end

      status = response.code.to_i
      if response.is_a?(Net::HTTPSuccess)
        # WNS は 200 でも X-WNS-NotificationStatus が dropped / channelthrottled の
        # ことがある。配信自体は受理されたものとして success 扱いにし、観測のため
        # ステータスだけ残す。
        return {success: true, status: status, wns_status: response['X-WNS-NotificationStatus']}
      end

      return {
        success: false,
        status: status,
        reason: response['X-WNS-Error-Description'] || response['X-WNS-Status'] || response.message,
        permanent: PERMANENT_STATUSES.include?(status),
        oversized: status == OVERSIZED_STATUS,
      }
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
