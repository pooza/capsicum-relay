require_relative '../app_store_verification'
require_relative '../base_app'

module Relay
  module Routes
    # 有償リレーの利用権 (capsicum#597 / #58)。**フェーズ 1（認証）。**
    #
    # ⚠⚠ **この route は誰も拒まない。**`/register` も `/push` も従来どおり通る
    # （ゲートはフェーズ 2 / #60、レシート検証はフェーズ 3 / #61 / #62）。ここで
    # 作るのは「誰から来たかを言えるようにする」ための記録だけ。
    #
    # ⚠⚠ **発行された token は「購入した証拠」ではない。**認証は共有シークレット
    # 1 本で、**そのシークレットはバイナリから取り出せる**（capsicum#1121 の
    # 「`RELAY_SECRET` は authorization boundary にできない」）。つまりこの
    # エンドポイントは実質的に開いており、**誰でも好きな `purchase_id` で
    # `unverified` の行を作れる**。フェーズ 3 でレシートを検証して初めて
    # `active` になる。
    #
    # **Apple はその場で確かめる (#61)。**`purchase_id`（StoreKit の transactionId）で
    # App Store Server API を引き、状態と元の取引 ID を反映してから応答する。
    # ⚠ Apple に届かないときは `unverified` のまま返す（fail-open・判断は
    # [Relay::AppStoreVerification]）。Google / Microsoft は #62 以降。
    class Entitlements < BaseApp
      post '/entitlements' do
        authenticate!
        require_fields!('store', 'purchase_id', 'device_id')
        validate_store!

        token = settings.database.issue_entitlement_token(
          store: json_body['store'],
          purchase_id: json_body['purchase_id'],
          product_id: json_body['product_id'],
          device_id: json_body['device_id'],
        )

        token, verification = verified(token)

        metrics.increment('relay_entitlement_token_total', {store: token['store']})
        log_event(
          'entitlement.issued',
          # ⚠ **`purchase_id` も `token` もログに出さない。**前者はストアの購入を
          # 名指しでき、後者はそのまま利用権として使える。切り分けに要るのは
          # 「どのストアの・どの商品が・端末いくつぶん」までで、個体は要らない。
          msg: "Entitlement token issued: #{token['store']} (#{token['status']})",
          store: token['store'],
          product_id: token['product_id'],
          status: token['status'],
          environment: token['environment'],
          verification: verification,
          device_count: settings.database
            .entitlement_tokens_for_purchase(token['store'], token['purchase_id']).size,
          latency_ms: latency_ms,
        )
        status 201
        entitlement_response(token).to_json
      end

      helpers do
        # Apple の購入ならその場で確かめる。戻り値は `[token, outcome]`（確かめ
        # なかったときの outcome は nil）。
        #
        # ⚠ 検証で行が寄った（元の取引 ID の行が既にあった）ときは、**寄せた先の
        # token を返し直す**。クライアントの手元の token はそれで置き換わる。
        def verified(token)
          return [token, nil] unless token['store'] == 'apple' && settings.app_store

          outcome, entitlement_id = Relay::AppStoreVerification.verify!(
            settings,
            entitlement_id: token['entitlement_id'],
            transaction_id: json_body['purchase_id'],
          )
          metrics.increment('relay_entitlement_verify_total', {store: 'apple', outcome: outcome})
          return [
            settings.database.entitlement_token_for(entitlement_id, json_body['device_id']),
            outcome,
          ]
        end

        def validate_store!
          return if Relay::Database::ENTITLEMENT_STORES.include?(json_body['store'])

          halt 400, {
            error: "store must be one of #{Relay::Database::ENTITLEMENT_STORES.join(', ')}",
          }.to_json
        end

        # クライアントへ返す形。
        #
        # ⚠ **内部 id を返さない。**クライアントが持つ必要があるのは `token` だけで
        # （`/register` に載せる・capsicum#1121）、行 id を渡すと「id で引ける」と
        # 誤解される導線ができる。
        #
        # ⚠ `purchase_id` は**返す**（送ってきた値なので新しい情報ではなく、
        # どの購入に対する応答かを突き合わせられる）。
        def entitlement_response(token)
          return {
            token: token['token'],
            store: token['store'],
            purchase_id: token['purchase_id'],
            product_id: token['product_id'],
            status: token['status'],
            expires_at: token['expires_at'],
            environment: token['environment'],
          }
        end
      end
    end
  end
end
