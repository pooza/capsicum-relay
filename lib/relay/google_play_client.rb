require 'googleauth'
require 'googleauth/id_tokens'
require 'json'
require 'net/http'
require 'time'
require 'uri'
require_relative 'entitlement_gate'
require_relative 'store_errors'

module Relay
  # Google Play Developer API でサブスクの状態を引く (#62)。
  #
  # ⚠⚠ **購入の状態は常にここから引き直す**（Apple の [Relay::AppStoreClient] と同じ）。
  # クライアントの申告も、Pub/Sub の通知（RTDN）も「どの購入か」を知るためにだけ使う。
  #
  # ⚠ 使う鍵は **relay 専用のサービスアカウント**（Firebase 用のものとは分ける）。
  # Play Console の「ユーザーと権限」で招待し、アプリの注文とサブスクの権限を付ける。
  # 権限が無い・外されたときは 401 / 403 が返るので、error ログを出して [Unavailable]。
  #
  # ⚠ Google は **purchaseToken がそのまま購入の識別子**（Apple のように更新のたびに
  # 変わらない）。再購入・プラン変更では新しい token になり、`linkedPurchaseToken` で
  # 前の token を指す。新しい token はクライアントが送り直すので、ここでは追わない。
  class GooglePlayClient
    class Unavailable < Relay::StoreUnavailable; end

    # Pub/Sub の push に付く OIDC トークンを検証して、中身（claims）を返す。
    # 通らなければ `Google::Auth::IDTokens::VerificationError`、Google の公開鍵が
    # 取れなければ `KeySourceError`（[Relay::Routes::GooglePlayNotifications] が分けて扱う）。
    module OidcVerifier
      def self.call(token, audience)
        return Google::Auth::IDTokens.verify_oidc(token, aud: audience)
      end
    end

    ENDPOINT = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/' \
      '%{package}/purchases/subscriptionsv2/tokens/%{token}'.freeze
    SCOPE = 'https://www.googleapis.com/auth/androidpublisher'.freeze

    # Google のサブスク状態 → `entitlements.status`。
    #
    # - ⚠ `CANCELED` は**自動更新を止めただけ**で、期限までは使える（→ 期限で分ける）
    # - `ON_HOLD`（アカウントの保留・支払い失敗が続いている）は Apple の `billing_retry` と
    #   同じく**拒否側**。`IN_GRACE_PERIOD` は `grace`（許可側）
    # - `PENDING`（支払いが保留中・まだ払われていない）は `pending`（拒否側）
    STATES = {
      'SUBSCRIPTION_STATE_ACTIVE' => 'active',
      'SUBSCRIPTION_STATE_IN_GRACE_PERIOD' => 'grace',
      'SUBSCRIPTION_STATE_ON_HOLD' => 'billing_retry',
      'SUBSCRIPTION_STATE_PAUSED' => 'expired',
      'SUBSCRIPTION_STATE_EXPIRED' => 'expired',
      'SUBSCRIPTION_STATE_PENDING' => 'pending',
      'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED' => 'expired',
    }.freeze
    CANCELED = 'SUBSCRIPTION_STATE_CANCELED'.freeze

    Result = Struct.new(
      :purchase_id, :product_id, :status, :expires_at, :environment, :signed_at,
      keyword_init: true
    )

    # settings.yml 全体から組み立てる。⚠ `google_play.service_account_path` が無ければ nil
    # （検証しない＝従来どおり `unverified` のまま・通知の受け口は 503）。
    def self.from_config(config, logger:)
      section = config['google_play']
      return nil unless section&.dig('service_account_path')

      return new(section, logger: logger)
    end

    # [config] は settings.yml の `google_play` 節。
    #
    # - `package_name`: Android の applicationId（製品版は `net.shrieker.capsicum`）
    # - `service_account_path`: relay 専用のサービスアカウントの鍵（JSON）
    #
    # [http] / [token_source] / [clock] はテストの差し替え口。
    def initialize(config, logger:, http: nil, token_source: nil, clock: -> {Time.now})
      @package_name = config.fetch('package_name')
      @logger = logger
      @http = http || method(:request)
      @token_source = token_source || build_token_source(config.fetch('service_account_path'))
      @clock = clock
    end

    attr_reader :package_name

    # [purchase_token] の購入を引く。見つからなければ nil。
    def purchase_status(purchase_token)
      # ⚠ Google の応答は署名時刻を持たないので、**問い合わせを始めた時刻**を順序に使う
      # （[Relay::Database#apply_entitlement_verification] の `signed_at`）。
      asked_at = (@clock.call.to_f * 1000).to_i
      code, body = @http.call(url_for(purchase_token), access_token)
      return result_from(parse(body), purchase_token, asked_at) if code == 200
      return nil if [400, 404, 410].include?(code)

      if [401, 403].include?(code)
        # ⚠ サービスアカウントの権限が無い・外された。**全購入の検証が止まる**ので error。
        @logger.error("Google Play Developer API rejected the service account: #{code}")
      end
      raise Unavailable, "Google Play Developer API: #{code}"
    end

    private

    def url_for(purchase_token)
      return ENDPOINT % {package: URI.encode_uri_component(@package_name),
        token: URI.encode_uri_component(purchase_token.to_s)}
    end

    def parse(body)
      json = JSON.parse(body.to_s)
      raise Relay::StoreResponseInvalid, 'response is not an object' unless json.is_a?(Hash)

      return json
    rescue JSON::ParserError
      raise Relay::StoreResponseInvalid, 'response is not JSON'
    end

    def result_from(json, purchase_token, asked_at)
      line = Array(json['lineItems']).max_by {|item| item['expiryTime'].to_s}
      expiry = parse_time(line&.dig('expiryTime'))
      status = status_for(json['subscriptionState'], expiry)
      # ⚠⚠ **許可側の状態なのに期限が読めない応答は使わない**（Codex P2・PR #76）。ゲートは
      # 状態しか見ないので、期限の無い `active` を保存すると**無期限に通る**。形の崩れた
      # 応答・API の変更は「確かめられなかった」として、いまの状態を残す。
      if Relay::EntitlementGate::ENTITLED_STATUSES.include?(status) && expiry.nil?
        raise Relay::StoreResponseInvalid, "#{status} without a valid expiryTime"
      end

      return Result.new(
        purchase_id: purchase_token,
        product_id: line&.dig('productId'),
        status: status,
        expires_at: expiry&.utc&.strftime('%Y-%m-%d %H:%M:%S'),
        # ⚠ ライセンステスターの購入は `testPurchase` を持つ。Apple の TestFlight と同じく
        # `Sandbox` の印を付ける（本番でも有効に扱う・テスターは身内だけの前提）。
        environment: json.key?('testPurchase') ? 'Sandbox' : 'Production',
        signed_at: asked_at,
      )
    end

    def status_for(state, expiry)
      if state == CANCELED
        return expiry && expiry > @clock.call ? 'active' : 'expired'
      end
      return STATES.fetch(state) do
        @logger.warn("Unknown Google Play subscription state: #{state}")
        'expired'
      end
    end

    def parse_time(value)
      return nil unless value

      return Time.iso8601(value)
    rescue ArgumentError
      return nil
    end

    # アクセストークン。googleauth が期限まで持ち回す。
    def access_token
      return @token_source.call
    rescue Relay::StoreUnavailable
      raise
    rescue StandardError => e
      raise Unavailable, "access token: #{e.class}: #{e.message}"
    end

    def build_token_source(path)
      credentials = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: File.open(path), scope: SCOPE,
      )
      return lambda do
        if credentials.access_token.nil? || credentials.expires_within?(60)
          credentials.fetch_access_token!
        end
        credentials.access_token
      end
    end

    def request(url, token)
      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{token}"
      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10
      ) {|http| http.request(request)}
      return [response.code.to_i, response.body]
    # ⚠ `SocketError`（名前解決の失敗）は `SystemCallError` ではないので別に書く。
    rescue SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
      Net::ProtocolError => e
      raise Unavailable, "#{e.class}: #{e.message}"
    end
  end
end
