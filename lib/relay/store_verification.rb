require_relative 'database'
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
