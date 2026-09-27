require_relative 'app_store_client'
require_relative 'database'
require_relative 'google_play_client'
require_relative 'store_errors'

module Relay
  # ストア（Apple / Google）の購入を API で確かめ、結果を `entitlements` へ反映する
  # (#61 / #62)。
  #
  # ⚠ **入口は 3 つ**（`POST /entitlements`・各ストアの通知の受け口・確かめ直しの
  # ワーカー）で、ストアも 2 つある。判断を複数か所に書くと片方だけ fail-open や
  # 順序の守りを忘れるので、**ここ 1 か所に置く**。ストアごとの違いはクライアント
  # （`purchase_status` を持つ）に閉じる。
  module StoreVerification
    # ストア名 → そのクライアントを持つ settings の名前。
    CLIENTS = {'apple' => :app_store, 'google' => :google_play}.freeze

    # 購入ごとの鍵（Codex P2・PR #75）。
    #
    # ⚠⚠ **「ストアから読む → 書く」を同じ行については 1 本ずつにする。**⚠ 付け替え前の
    # 行は購入ごとに別の行 ID を持つので、鍵だけでは足りない。古い結果での上書きは
    # ストアの時刻（`signed_at`）の比較が防ぐ（[Relay::Database#apply_entitlement_verification]）。
    #
    # ⚠ **全体で 1 本の鍵にしない。**ストアが遅いとき（タイムアウトまで最大 30 秒）に
    # puma の 2 本のスレッドが両方待たされ、**push の受け付けまで止まる**。
    LOCKS = Hash.new {|locks, id| locks[id] = Mutex.new}
    LOCKS_GUARD = Mutex.new

    def self.lock_for(entitlement_id)
      return LOCKS_GUARD.synchronize {LOCKS[entitlement_id]}
    end

    # アプリの設定にストアまわりを組み立てる（[Relay::BaseApp] の `configure` から呼ぶ）。
    #
    # - `apple_jws_verifier`: ⚠ **1 つを共有する**（API の応答と通知の両方が同じルート
    #   証明書で検証される・テストはここを差し替える）
    # - `app_store` / `google_play`: ⚠ **設定が無ければ nil ＝ 確かめない**（従来どおり
    #   `unverified` のまま・通知の受け口は 503）
    # - `entitlement_reverifier`: `unverified` のまま残った購入を確かめ直す（Codex P1・PR #75）
    def self.configure!(app)
      settings = app.settings
      app.set :apple_jws_verifier, Relay::AppleJwsVerifier.new
      app.set :app_store, Relay::AppStoreClient.from_config(
        settings.config, logger: settings.logger, verifier: settings.apple_jws_verifier
      )
      app.set :google_play,
        Relay::GooglePlayClient.from_config(settings.config, logger: settings.logger)
      # Pub/Sub の push に付く OIDC トークンの検証（テストはここを差し替える）。
      # ⚠ **Proc を `set` しない。**Sinatra は Proc の設定を読み出すたびに呼び出すので、
      # `call` を持つモジュールで渡す。
      app.set :google_oidc_verifier, Relay::GooglePlayClient::OidcVerifier
      app.set :entitlement_reverifier, Relay::EntitlementReverifier.start_from_settings(settings)
    end

    # そのストアのクライアント。設定されていなければ nil（確かめない）。
    def self.client_for(settings, store)
      name = CLIENTS[store]
      return nil unless name && settings.respond_to?(name)

      return settings.public_send(name)
    end

    # [purchase_ref] の購入を引き直し、[entitlement_id] の行へ反映する。
    # [purchase_ref] は Apple なら StoreKit の transactionId（元の取引でも更新後でも）、
    # Google なら purchaseToken。
    #
    # 戻り値は `[outcome, entitlement_id]`。検証で行が寄ったときは寄せた先の id。
    #
    # | outcome | 意味 | 行 |
    # | --- | --- | --- |
    # | `active` 等 | ストアの状態 | 反映した |
    # | `not_found` | ストアに無い購入 | 触らない（`unverified` のまま） |
    # | `unavailable` | ストアに届かない・鍵や権限が使えない | ⚠⚠ **触らない（fail-open）** |
    # | `invalid` | 署名・宛先が合わない | 触らない |
    def self.verify!(settings, store:, entitlement_id:, purchase_ref:)
      return lock_for(entitlement_id).synchronize do
        verify_locked(settings, store, entitlement_id, purchase_ref)
      end
    end

    def self.verify_locked(settings, store, entitlement_id, purchase_ref)
      result = client_for(settings, store).purchase_status(purchase_ref)
      return ['not_found', entitlement_id] unless result

      id = settings.database.apply_entitlement_verification(
        entitlement_id, verification_of(store, result)
      )
      return [result.status, id]
    rescue Relay::StoreUnavailable => e
      # ⚠⚠ **有効な購入を「確かめられなかった」だけで失効扱いにしない。**
      settings.logger.warn("Store verification unavailable (#{store}, state kept): #{e.message}")
      return ['unavailable', entitlement_id]
    rescue Relay::StoreResponseInvalid => e
      settings.logger.warn("Store response failed verification (#{store}): #{e.message}")
      return ['invalid', entitlement_id]
    end

    def self.verification_of(store, result)
      return Relay::Database::EntitlementVerification.new(
        store: store,
        purchase_id: result.purchase_id,
        product_id: result.product_id,
        status: result.status,
        expires_at: result.expires_at,
        environment: result.environment,
        signed_at: result.signed_at,
      )
    end
    private_class_method :verify_locked, :verification_of
  end
end

require_relative 'entitlement_reverifier'
