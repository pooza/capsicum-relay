require_relative 'apple_jws_verifier'
require_relative 'store_errors'

module Relay
  # App Store Server API の応答から、リレー利用権の取引を選ぶ (#89 / #93)。
  #
  # [Relay::AppStoreClient] に混ぜて使う。`@verifier` / `@bundle_id` /
  # `@product_ids` / `@logger` を読む。
  #
  # ⚠ クライアント本体から切り出したのは、応答の読み方（どの取引を採るか・
  # 検証に落ちた件をどう扱うか）が HTTP の話と別の関心で、ここだけで読めるように
  # するため。
  module AppStoreTransactions
    private

    # `[lastTransactions の 1 件, 検証済みの取引]`。取引が 1 件も無ければ nil。
    # ⚠ 候補が複数あるときは、有効なもの → 期限の遅いものを取る。
    #
    # ⚠ 取引はあるのに利用権の商品が無ければ [Relay::StoreProductMismatch]（#93）。
    def entitlement_transaction(body)
      entries = Array(body['data']).flat_map {|group| Array(group['lastTransactions'])}
      verified, rejected = verify_entries(entries)
      matched = verified.select {|_, transaction| @product_ids.include?(transaction['productId'])}
      return pick_latest(matched) unless matched.empty?

      # ⚠⚠ **検証に落ちた件があって一致が 0 件なら、「無い」とは言わない** (#93)。
      # 落ちた 1 件が利用権の取引だったかもしれないので、確かめられなかった側へ倒す。
      raise rejected.first if rejected.any?
      return nil if verified.empty?

      products = verified.map {|_, transaction| transaction['productId']}.uniq.join(', ')
      # ⚠ **event 名を付けて残す。**この行が「商品の設定が合っていない」を知らせる。
      msg = "App Store purchase is not a relay entitlement product: #{products}"
      @logger.warn({event: 'entitlement.product_mismatch', store: 'apple', products: products,
msg: msg})
      raise Relay::StoreProductMismatch, msg
    end

    # 全グループの取引の署名を検証する。`[検証できた [last, 取引] の列, 落ちた例外の列]`。
    #
    # ⚠⚠ **無関係な 1 件の検証失敗で、全体を落とさない** (#93)。`productId` は署名の
    # 中にあるので、商品で絞る前に検証するしかない。以前は別グループの 1 件が検証に
    # 落ちると例外で抜け、**利用権の商品が正常でも結果を得られなかった**（サブスクが
    # 1 本のうちは起きないが、2 本目を足すと効く）。落ちた件は warn して除く。
    def verify_entries(entries)
      verified = []
      rejected = []
      entries.each do |last|
        verified << [last, verified_transaction(last)]
      rescue AppleJwsVerifier::Invalid => e
        @logger.warn("App Store transaction failed verification (skipped): #{e.message}")
        rejected << e
      end
      return [verified, rejected]
    end

    def pick_latest(matched)
      return matched.max_by do |last, transaction|
        [last['status'] == 1 ? 1 : 0, transaction['expiresDate'].to_i]
      end
    end

    def verified_transaction(last)
      transaction = @verifier.verify(last['signedTransactionInfo'])
      unless transaction['bundleId'] == @bundle_id
        raise AppleJwsVerifier::Invalid, "bundleId mismatch: #{transaction['bundleId']}"
      end

      return transaction
    end
  end
end
