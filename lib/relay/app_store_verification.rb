require_relative 'app_store_client'

module Relay
  # Apple の購入を App Store Server API で確かめ、結果を `entitlements` へ反映する (#61)。
  #
  # ⚠ **入口は 2 つ**（`POST /entitlements` と `POST /store/apple/notifications`）。
  # 判断を 2 か所に書くと片方だけ fail-open を忘れるので、ここ 1 か所に置く。
  module AppStoreVerification
    # 購入ごとの鍵（Codex P2・PR #75）。
    #
    # ⚠⚠ **「Apple から読む → 書く」を同じ購入については 1 本ずつにする。**読みと書きの
    # 間に別の検証が割り込むと、**古い読み（active）が新しい書き（expired）を上書き**して、
    # 失効した購入が有効に戻る。
    #
    # ⚠ **全体で 1 本の鍵にしない。**Apple が遅いとき（タイムアウトまで最大 30 秒）に
    # puma の 2 本のスレッドが両方待たされ、**push の受け付けまで止まる**。
    LOCKS = Hash.new {|locks, id| locks[id] = Mutex.new}
    LOCKS_GUARD = Mutex.new

    def self.lock_for(entitlement_id)
      return LOCKS_GUARD.synchronize {LOCKS[entitlement_id]}
    end

    # [transaction_id] の購入を引き直し、[entitlement_id] の行へ反映する。
    #
    # 戻り値は `[outcome, entitlement_id]`。検証で行が寄ったときは寄せた先の id。
    #
    # | outcome | 意味 | 行 |
    # | --- | --- | --- |
    # | `active` 等 | Apple の状態（[AppStoreClient::STATUSES]） | 反映した |
    # | `not_found` | どの環境にも無い取引 | 触らない（`unverified` のまま） |
    # | `unavailable` | Apple に届かない・鍵が使えない | ⚠⚠ **触らない（fail-open）** |
    # | `invalid` | 署名・bundleId が合わない | 触らない |
    def self.verify!(settings, entitlement_id:, transaction_id:)
      return lock_for(entitlement_id).synchronize do
        verify_locked(settings, entitlement_id, transaction_id)
      end
    end

    def self.verify_locked(settings, entitlement_id, transaction_id)
      result = settings.app_store.subscription_status(transaction_id)
      return ['not_found', entitlement_id] unless result

      id = settings.database.apply_entitlement_verification(entitlement_id, verification_of(result))
      return [result.status, id]
    rescue AppStoreClient::Unavailable => e
      # ⚠⚠ **有効な購入を「確かめられなかった」だけで失効扱いにしない。**
      settings.logger.warn("App Store verification unavailable (state kept): #{e.message}")
      return ['unavailable', entitlement_id]
    rescue AppleJwsVerifier::Invalid => e
      settings.logger.warn("App Store response failed verification: #{e.message}")
      return ['invalid', entitlement_id]
    end

    def self.verification_of(result)
      return Relay::Database::EntitlementVerification.new(
        store: 'apple',
        purchase_id: result.original_transaction_id,
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
