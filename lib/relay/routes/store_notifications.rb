require_relative '../store_verification'
require_relative '../apple_jws_verifier'
require_relative '../base_app'

module Relay
  module Routes
    # ストアからのサーバー通知の受け口 (#61)。**Apple（App Store Server
    # Notifications V2）だけ。**Google（RTDN）は #62。
    #
    # ⚠⚠ **共有シークレットを見ない**（Apple は付けられない）。代わりに
    # `signedPayload` の署名を Apple のルート証明書まで検証する
    # （[Relay::AppleJwsVerifier]）。**署名が通らないものは 400 で捨てる。**
    #
    # ⚠⚠ **中身の状態は使わない。**通知から取り出すのは「どの購入か」（元の取引 ID）
    # だけで、状態は App Store Server API で引き直す（[Relay::StoreVerification]）。
    # Apple は通知の順序を保証しないし、同じ通知を再送もする。引き直せば、いつ
    # 処理しても Apple 側の最新の状態になる。
    #
    # 応答:
    #
    # | status | いつ | Apple の動き |
    # | --- | --- | --- |
    # | 200 | 反映した・知らない購入・テスト通知・別アプリ宛て | 再送しない |
    # | 400 | 署名が通らない・形が違う | 再送しない（⚠ 本物なら Apple 側の問題） |
    # | 503 | 検証の設定が無い・Apple API に届かない | ⚠ **再送する**（時間をおいて最大 5 回） |
    #
    # ⚠ **503 は「あとでもう一度」の意味で使う。**Apple API の一時的な障害で
    # 更新・失効を取りこぼさないため。
    #
    # URL は App Store Connect の「App Store Server Notifications」に設定する。
    # ⚠ **本番 URL は relay、サンドボックス URL は st.relay**（2026-09-27 決定）。
    class StoreNotifications < BaseApp
      post '/store/apple/notifications' do
        halt 503, {error: 'app_store is not configured'}.to_json unless settings.app_store

        notification = verified_notification
        type = notification['notificationType'].to_s
        outcome = handle_apple_notification(notification, type)
        metrics.increment(
          'relay_store_notification_total', {store: 'apple', type: type, outcome: outcome}
        )
        log_event(
          'store.notification',
          msg: "Apple notification: #{type} (#{outcome})",
          store: 'apple',
          type: type,
          subtype: notification['subtype'],
          environment: notification.dig('data', 'environment'),
          outcome: outcome,
          latency_ms: latency_ms,
        )
        halt 503, {error: 'verification unavailable'}.to_json if outcome == 'unavailable'

        status 200
        {status: 'ok'}.to_json
      end

      helpers do
        def apple_verifier
          return settings.apple_jws_verifier
        end

        def verified_notification
          signed = json_body['signedPayload']
          halt 400, {error: 'signedPayload is required'}.to_json unless signed.is_a?(String)

          return apple_verifier.verify(signed)
        rescue AppleJwsVerifier::Invalid => e
          reject_invalid!(e.message)
        end

        # 通知に入っている取引情報も署名を確かめる。⚠ 外側（`signedPayload`）が
        # 通っても、中身だけ差し替えられていないとは言えない。
        def verified_transaction(signed_transaction)
          return apple_verifier.verify(signed_transaction)
        rescue AppleJwsVerifier::Invalid => e
          reject_invalid!("signedTransactionInfo: #{e.message}")
        end

        # ⚠ **元の取引 ID だけで引かない**（Codex P1・PR #75）。購入の登録時に Apple へ
        # 届かなかった（fail-open）行は、クライアントが送った transactionId のまま
        # `unverified` で残っている。初回購入の通知はその transactionId を持って来るので、
        # そちらでも引く。見つかれば検証で元の取引 ID へ付け替わる。
        def find_apple_entitlement(original_id, transaction_id)
          found = settings.database.find_entitlement('apple', original_id)
          return found if found || transaction_id.empty?

          return settings.database.find_entitlement('apple', transaction_id)
        end

        def reject_invalid!(message)
          metrics.increment(
            'relay_store_notification_total', {store: 'apple', type: 'unknown', outcome: 'invalid'}
          )
          log_event(
            'store.notification', level: :warn,
            msg: "Apple notification rejected: #{message}", store: 'apple', outcome: 'invalid'
          )
          halt 400, {error: 'invalid signature'}.to_json
        end

        # ⚠ 戻り値は metrics / log の `outcome`。**購入の識別子はログに出さない**
        # （[Relay::Routes::Entitlements] と同じ方針）。
        def handle_apple_notification(notification, type)
          return 'test' if type == 'TEST'

          data = notification['data'] || {}
          return 'other_app' unless data['bundleId'] == settings.app_store.bundle_id

          signed_transaction = data['signedTransactionInfo']
          return 'no_transaction' unless signed_transaction

          transaction = verified_transaction(signed_transaction)
          original_id = transaction['originalTransactionId'].to_s
          entitlement = find_apple_entitlement(original_id, transaction['transactionId'].to_s)
          return 'unknown_purchase' unless entitlement

          outcome, = Relay::StoreVerification.verify!(
            settings, store: 'apple', entitlement_id: entitlement['id'], purchase_ref: original_id
          )
          metrics.increment('relay_entitlement_verify_total', {store: 'apple', outcome: outcome})
          return outcome
        end
      end
    end
  end
end
