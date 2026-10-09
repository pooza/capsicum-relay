require 'json'
require 'jwt'
require 'net/http'
require 'openssl'
require 'uri'
require_relative 'apple_jws_verifier'
require_relative 'app_store_transactions'
require_relative 'entitlement_products'
require_relative 'store_errors'

module Relay
  # App Store Server API でサブスクの状態を引く (#61)。
  #
  # ⚠⚠ **購入の状態は常にここから引き直す。**クライアントの申告も、Server
  # Notifications の中身も、「どの購入か」を知るためにだけ使う。順序の入れ替わりや
  # 重複した通知に振り回されず、いつ引いても Apple 側の最新の状態になる。
  #
  # ⚠ 使う鍵は **アプリ内課金キー**（App Store Connect → ユーザとアクセス → 統合 →
  # アプリ内課金）。⚠ **期限は無い**（失効は手動の revoke だけ）。revoke されると
  # 401 が返るので、そのときは [Unavailable] を投げてエラーログを出す。
  class AppStoreClient
    # Apple に届かない・Apple 側の障害・鍵が使えない。⚠ **呼び出し側は状態を
    # 変えずに抜ける（fail-open）。**有効な購入を「確かめられなかった」だけで
    # 失効扱いにしない。
    class Unavailable < Relay::StoreUnavailable; end

    # 応答の取引から、利用権の商品のものを選ぶ（#89 / #93）。
    include AppStoreTransactions

    HOSTS = {
      'Production' => 'api.storekit.itunes.apple.com',
      'Sandbox' => 'api.storekit-sandbox.itunes.apple.com',
    }.freeze

    # Apple のサブスク状態 → `entitlements.status`。
    #
    # ⚠ `billing_retry`（支払いに失敗して Apple が再試行中）は**拒否側**。猶予期間
    # （`grace`）を設定していない限り、Apple もこの間は利用させない扱い。
    STATUSES = {
      1 => 'active',
      2 => 'expired',
      3 => 'billing_retry',
      4 => 'grace',
      5 => 'revoked',
    }.freeze

    # 「その取引 ID は無い」。⚠ **Production で無ければ Sandbox を引く**（Apple が
    # 推奨する順。TestFlight の購入はサンドボックスになる）。
    NOT_FOUND_ERROR_CODES = [4_040_010, 4_000_006].freeze

    Result = Struct.new(
      :original_transaction_id, :product_id, :status, :expires_at, :environment, :signed_at,
      keyword_init: true
    ) do
      # 保存する購入の識別子。Apple は元の取引 ID（[Relay::StoreVerification]）。
      def purchase_id
        return original_transaction_id
      end
    end

    # [config] は settings.yml の `app_store` 節。
    #
    # - `key_id` / `issuer_id` / `key_path` / `bundle_id`
    # - `product_ids`: 利用権として扱う商品（省略時は [Relay::EntitlementProducts::DEFAULT]）
    # - `environments`: 引く順。本番 relay は `[Production, Sandbox]`、ステージングは
    #   `[Sandbox]`。⚠ 本番でサンドボックスの購入を扱うのは 2026-09-27 の決定
    #   （TestFlight のテスターは身内だけにする前提）
    # [hosts] はテストで名前解決できないホスト（`.invalid`）へ向けるための口。
    def initialize(config, logger:, verifier: AppleJwsVerifier.new, http: nil, hosts: HOSTS)
      @key_id = config.fetch('key_id')
      @issuer_id = config.fetch('issuer_id')
      @bundle_id = config.fetch('bundle_id')
      @product_ids = Relay::EntitlementProducts.from(config)
      @key = OpenSSL::PKey.read(File.read(config.fetch('key_path')))
      @environments = Array(config.fetch('environments', HOSTS.keys))
      @logger = logger
      @verifier = verifier
      @http = http || method(:request)
      @hosts = hosts
    end

    attr_reader :bundle_id

    # settings.yml 全体から組み立てる。⚠ `app_store.key_path` が無ければ nil
    # （検証しない＝従来どおり `unverified` のまま・通知の受け口は 503）。
    def self.from_config(config, logger:, verifier:)
      section = config['app_store']
      return nil unless section&.dig('key_path')

      return new(section, logger: logger, verifier: verifier)
    end

    # [transaction_id] はその購入に属する取引 ID ならどれでもよい（元の取引でも、
    # 更新後の取引でも）。見つからなければ nil。
    # [Relay::StoreVerification] から呼ばれる入口（ストア共通の名前）。
    def purchase_status(transaction_id)
      return subscription_status(transaction_id)
    end

    def subscription_status(transaction_id)
      @environments.each do |environment|
        body = fetch(environment,
          "/inApps/v1/subscriptions/#{URI.encode_uri_component(transaction_id.to_s)}")
        next unless body

        return result_from(body, environment)
      end
      return nil
    end

    private

    def fetch(environment, path)
      code, body = @http.call(environment, path, bearer_token)
      return JSON.parse(body) if code == 200

      json = parse_error(body)
      return nil if code.between?(400, 404) && NOT_FOUND_ERROR_CODES.include?(json['errorCode'])

      if code == 401
        # ⚠ 鍵が revoke された・issuer / key_id の取り違え。**全購入の検証が止まる**
        # ので error で出す。
        @logger.error("App Store Server API rejected the key (#{environment}): 401")
      end
      raise Unavailable, "App Store Server API #{environment}: #{code} #{json['errorCode']}"
    end

    def parse_error(body)
      return JSON.parse(body.to_s)
    rescue JSON::ParserError
      return {}
    end

    # ⚠⚠ **利用権の商品の取引だけを見る** (#89)。応答はアプリの**全サブスクグループ**を
    # 持って来るので、先頭を取るだけだと次の 2 つが起きる:
    #
    # - 別のサブスクの購入で、リレー利用権が `active` になる
    # - 別グループの失効した購読が先頭に来て、払っている人が `expired` と記録される
    #
    # ⚠ 取引が 1 件も無ければ nil（＝「その購入は知らない」）。取引はあるのに利用権の
    # 商品が無いときは [Relay::StoreProductMismatch] を投げる（#93・「知らない」と分ける）。
    def result_from(body, environment)
      last, transaction = entitlement_transaction(body)
      return nil unless last

      return Result.new(
        original_transaction_id: last['originalTransactionId'].to_s,
        product_id: transaction['productId'],
        status: STATUSES.fetch(last['status'], 'expired'),
        expires_at: iso8601_ms(transaction['expiresDate']),
        environment: body['environment'] || environment,
        # Apple がこの応答に署名した時刻（ミリ秒）。⚠ **古い結果で新しい結果を上書き
        # しないための順序**（[Relay::Database#apply_entitlement_verification]）。
        signed_at: transaction['signedDate'],
      )
    end

    def iso8601_ms(millis)
      return nil unless millis

      return Time.at(millis / 1000).utc.strftime('%Y-%m-%d %H:%M:%S')
    end

    # App Store Server API の認証。有効期限は最長 60 分なので 1 回ごとに作る
    # （ES256 の署名 1 回で、配送の頻度に比べて十分に安い）。
    def bearer_token
      now = Time.now.to_i
      return JWT.encode(
        {iss: @issuer_id, iat: now, exp: now + 600, aud: 'appstoreconnect-v1', bid: @bundle_id},
        @key, 'ES256', {kid: @key_id, typ: 'JWT'}
      )
    end

    def request(environment, path, token)
      uri = URI("https://#{@hosts.fetch(environment)}#{path}")
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{token}"
      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10
      ) {|http| http.request(request)}
      return [response.code.to_i, response.body]
    # ⚠ **`SocketError`（名前解決の失敗）は `SystemCallError` ではない**ので別に書く
    # （Codex P1・PR #75）。漏れると fail-open にならず 500 になる。
    rescue SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
      Net::ProtocolError => e
      raise Unavailable, "#{e.class}: #{e.message}"
    end
  end
end
