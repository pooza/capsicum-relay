require 'base64'
require 'json'
require_relative '../base_app'
require_relative '../store_verification'

module Relay
  module Routes
    # Google Play のリアルタイム デベロッパー通知（RTDN）の受け口 (#62)。
    #
    # Play Console に登録した Pub/Sub のトピックへ Google が通知を送り、**push の購読**が
    # ここへ届ける。⚠ 1 つのトピックに購読を 2 本付ければ、本番とステージングの両方で
    # 受けられる（Apple と違い、URL は 1 つに決め打たれない）。
    #
    # ⚠⚠ **共有シークレットを見ない**（Pub/Sub は付けられない）。代わりに Pub/Sub が付ける
    # **OIDC トークン**を検証する —— 宛先（`google_play.push_audience`）と、push の購読に
    # 設定したサービスアカウント（`google_play.push_service_account`）の両方を照合する。
    #
    # ⚠⚠ **中身の状態は使わない。**通知から取り出すのは purchaseToken だけで、状態は
    # Play Developer API で引き直す（[Relay::StoreVerification]）。
    #
    # 応答（Pub/Sub は 2xx 以外を失敗として**時間をおいて再送する**）:
    #
    # | status | いつ |
    # | --- | --- |
    # | 200 | 反映した・知らない購入・テスト通知・別アプリ宛て・サブスク以外（投げ銭の消耗型など） |
    # | 400 | 形が違う |
    # | 401 | OIDC トークンが無い・通らない・送り手が違う |
    # | 503 | 検証の設定が無い・Google の公開鍵や API に届かない（⚠ 再送させる） |
    class GooglePlayNotifications < BaseApp
      # `subscriptionNotification.notificationType` の名前（metrics / log 用）。
      SUBSCRIPTION_TYPES = {
        1 => 'RECOVERED', 2 => 'RENEWED', 3 => 'CANCELED', 4 => 'PURCHASED', 5 => 'ON_HOLD',
        6 => 'IN_GRACE_PERIOD', 7 => 'RESTARTED', 9 => 'DEFERRED', 10 => 'PAUSED',
        11 => 'PAUSE_SCHEDULE_CHANGED', 12 => 'REVOKED', 13 => 'EXPIRED',
        17 => 'ITEMS_CHANGED', 18 => 'CANCELLATION_SCHEDULED', 19 => 'PRICE_CHANGE_UPDATED',
        20 => 'PENDING_PURCHASE_CANCELED'
      }.freeze

      post '/store/google/notifications' do
        halt 503, {error: 'google_play is not configured'}.to_json unless settings.google_play

        authenticate_pubsub!
        notification = pubsub_notification
        type = google_type(notification)
        outcome = handle_google_notification(notification)
        metrics.increment(
          'relay_store_notification_total', {store: 'google', type: type, outcome: outcome}
        )
        log_event(
          'store.notification',
          msg: "Google Play notification: #{type} (#{outcome})",
          store: 'google', type: type, outcome: outcome, latency_ms: latency_ms
        )
        halt 503, {error: 'verification unavailable'}.to_json if outcome == 'unavailable'

        status 200
        {status: 'ok'}.to_json
      end

      helpers do
        # ⚠ 宛先と送り手の**両方**を見る。宛先だけだと、同じ URL を宛先にした別の
        # プロジェクトの Pub/Sub からも通ってしまう。
        def authenticate_pubsub!
          audience, sender = pubsub_auth_config
          token = request.env['HTTP_AUTHORIZATION'].to_s[/\ABearer (.+)\z/, 1]
          reject_pubsub!('missing bearer token') unless token

          claims = settings.google_oidc_verifier.call(token, audience)
          return if claims['email'] == sender && claims['email_verified'] == true

          reject_pubsub!("unexpected sender: #{claims['email']}")
        rescue Google::Auth::IDTokens::KeySourceError => e
          # Google の公開鍵が取れない。⚠ 再送させる（通知を捨てない）。
          settings.logger.warn("Pub/Sub OIDC keys unavailable: #{e.message}")
          halt 503, {error: 'key source unavailable'}.to_json
        rescue Google::Auth::IDTokens::VerificationError => e
          reject_pubsub!(e.message)
        end

        # 宛先（OIDC の audience）と送り手（push の購読に設定したサービスアカウント）。
        # ⚠ どちらかが無ければ 503（設定の書き忘れで通知を捨てない・再送させる）。
        def pubsub_auth_config
          config = settings.config['google_play'] || {}
          audience = config['push_audience']
          sender = config['push_service_account']
          return [audience, sender] if audience && sender

          halt 503, {error: 'push authentication is not configured'}.to_json
        end

        def reject_pubsub!(message)
          metrics.increment(
            'relay_store_notification_total', {store: 'google', type: 'unknown', outcome: 'invalid'}
          )
          log_event(
            'store.notification', level: :warn,
            msg: "Google Play notification rejected: #{message}",
            store: 'google', outcome: 'invalid'
          )
          halt 401, {error: 'unauthorized'}.to_json
        end

        # Pub/Sub の push は `{message: {data: <base64 の JSON>, ...}, subscription: ...}`。
        def pubsub_notification
          data = json_body.is_a?(Hash) ? json_body.dig('message', 'data') : nil
          halt 400, {error: 'message.data is required'}.to_json unless data.is_a?(String)

          notification = JSON.parse(Base64.decode64(data))
          halt 400, {error: 'message.data is not an object'}.to_json unless notification.is_a?(Hash)

          return notification
        rescue JSON::ParserError
          halt 400, {error: 'message.data is not JSON'}.to_json
        end

        def google_type(notification)
          return 'TEST' if notification['testNotification']
          return 'VOIDED' if notification['voidedPurchaseNotification']

          code = notification.dig('subscriptionNotification', 'notificationType')
          return SUBSCRIPTION_TYPES.fetch(code, "SUBSCRIPTION_#{code}") if code

          return 'OTHER'
        end

        # ⚠ 戻り値は metrics / log の `outcome`。**purchaseToken はログに出さない**
        # （そのまま購入を名指しできる）。
        def handle_google_notification(notification)
          return 'test' if notification['testNotification']
          return 'other_app' unless notification['packageName'] == settings.google_play.package_name

          token = purchase_token_of(notification)
          return 'no_subscription' unless token

          entitlement = settings.database.find_entitlement('google', token)
          return 'unknown_purchase' unless entitlement

          outcome, = Relay::StoreVerification.verify!(
            settings, store: 'google', entitlement_id: entitlement['id'], purchase_ref: token
          )
          metrics.increment('relay_entitlement_verify_total', {store: 'google', outcome: outcome})
          return outcome
        end

        # サブスクの通知と、返金・取り消し（voided）の通知が purchaseToken を持つ。
        # ⚠ 投げ銭（消耗型）の `oneTimeProductNotification` は利用権と関係ないので拾わない。
        def purchase_token_of(notification)
          return notification.dig('subscriptionNotification', 'purchaseToken') ||
              notification.dig('voidedPurchaseNotification', 'purchaseToken')
        end
      end
    end
  end
end
