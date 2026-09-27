require_relative 'support/request_test_case'
require 'base64'

# #62: Google の購入の検証。入口は `POST /entitlements`（store: google）と
# `POST /store/google/notifications`（Pub/Sub の push）。
#
# Play Developer API と OIDC の検証は偽物に差し替える。
class GooglePlayVerificationRouteTest < RequestTestCase
  PACKAGE = 'net.shrieker.capsicum'.freeze
  AUDIENCE = 'https://relay.example.test/store/google/notifications'.freeze
  SENDER = 'pubsub-push@capsicum-7a951.iam.gserviceaccount.com'.freeze

  # Play Developer API の偽物。purchaseToken ごとに結果を決めておく。
  class FakeGooglePlay
    attr_reader :calls

    def initialize(results)
      @results = results
      @calls = []
    end

    def package_name
      return PACKAGE
    end

    def purchase_status(token)
      @calls << token
      result = @results[token]
      raise Relay::GooglePlayClient::Unavailable, 'down' if result == :unavailable

      return result
    end
  end

  def result(status, token: 'token-1', environment: 'Production', signed_at: 1)
    return Relay::GooglePlayClient::Result.new(
      purchase_id: token, product_id: 'relay.monthly', status: status,
      expires_at: '2026-10-27 12:00:00', environment: environment, signed_at: signed_at
    )
  end

  # OIDC の検証の偽物。トークン文字列で結果を決める。
  # ⚠ Proc にしない（Sinatra の `set` は Proc を読み出しのたびに呼ぶ）。
  module Verifier
    def self.call(token, audience)
      raise Google::Auth::IDTokens::VerificationError, 'bad audience' unless audience == AUDIENCE

      case token
      when 'good' then {'email' => SENDER, 'email_verified' => true}
      when 'stranger' then {'email' => 'someone@example.test', 'email_verified' => true}
      when 'unverified-email' then {'email' => SENDER, 'email_verified' => false}
      when 'keys-down' then raise Google::Auth::IDTokens::KeySourceError, 'certs unavailable'
      else raise Google::Auth::IDTokens::VerificationError, 'signature'
      end
    end
  end

  def with_google(fake, config: {'push_audience' => AUDIENCE, 'push_service_account' => SENDER})
    settings = Relay::BaseApp.settings
    previous = [settings.google_play, settings.google_oidc_verifier, settings.config['google_play']]
    Relay::BaseApp.set(:google_play, fake)
    Relay::BaseApp.set(:google_oidc_verifier, Verifier)
    settings.config['google_play'] = config
    yield
  ensure
    Relay::BaseApp.set(:google_play, previous[0])
    Relay::BaseApp.set(:google_oidc_verifier, previous[1])
    settings.config['google_play'] = previous[2]
  end

  def purchase(token = 'token-1', device_id: 'device-1')
    post_json(
      '/entitlements',
      {store: 'google', purchase_id: token, product_id: 'relay.monthly', device_id: device_id},
    )
    return json_response
  end

  def notify(payload, bearer: 'good')
    body = {message: {data: Base64.strict_encode64(payload.to_json), messageId: '1'}}
    headers = {'CONTENT_TYPE' => 'application/json'}
    headers['HTTP_AUTHORIZATION'] = "Bearer #{bearer}" if bearer
    post('/store/google/notifications', body.to_json, headers)
  end

  def subscription(type, token: 'token-1', package: PACKAGE)
    return {
      'packageName' => package, 'eventTimeMillis' => '1790000000000',
      'subscriptionNotification' => {'notificationType' => type, 'purchaseToken' => token}
    }
  end

  def notification_count(type, outcome)
    return Relay::App.settings.metrics.value(
      'relay_store_notification_total', {store: 'google', type: type, outcome: outcome}
    )
  end

  # --- POST /entitlements ------------------------------------------------------

  def test_verified_purchase_is_active
    with_google(FakeGooglePlay.new({'token-1' => result('active')})) do
      body = purchase

      assert_equal(201, last_response.status)
      assert_equal('active', body['status'])
      assert_equal('token-1', body['purchase_id'])
      assert_equal('Production', body['environment'])
    end
  end

  # ライセンステスター（TestFlight と同じく本番でも有効・印を付ける）。
  def test_license_tester_purchase_is_active_with_sandbox_mark
    with_google(FakeGooglePlay.new({'token-1' => result('active', environment: 'Sandbox')})) do
      assert_equal('Sandbox', purchase['environment'])
    end
  end

  # ⚠⚠ fail-open。Google に届かなくても 201 で返し、`unverified` のまま残す。
  def test_unavailable_keeps_unverified
    with_google(FakeGooglePlay.new({'token-1' => :unavailable})) do
      assert_equal(201, last_response.status) if purchase

      assert_equal('unverified', json_response['status'])
    end
  end

  def test_pending_payment_is_not_entitled
    with_google(FakeGooglePlay.new({'token-1' => result('pending')})) do
      assert_equal('pending', purchase['status'])
    end
  end

  # --- POST /store/google/notifications（認証） --------------------------------

  def test_missing_bearer_is_rejected
    with_google(FakeGooglePlay.new({})) do
      notify(subscription(2), bearer: nil)

      assert_equal(401, last_response.status)
    end
  end

  def test_invalid_token_is_rejected
    with_google(FakeGooglePlay.new({})) do
      notify(subscription(2), bearer: 'forged')

      assert_equal(401, last_response.status)
      assert_equal(1, notification_count('unknown', 'invalid'))
    end
  end

  # ⚠⚠ 宛先が合っていても、送り手（push の購読のサービスアカウント）が違えば拒む。
  def test_other_sender_is_rejected
    with_google(FakeGooglePlay.new({})) do
      notify(subscription(2), bearer: 'stranger')

      assert_equal(401, last_response.status)
    end
  end

  def test_unverified_sender_email_is_rejected
    with_google(FakeGooglePlay.new({})) do
      notify(subscription(2), bearer: 'unverified-email')

      assert_equal(401, last_response.status)
    end
  end

  # ⚠ Google の公開鍵が取れないときは 503（Pub/Sub に再送させる・通知を捨てない）。
  def test_key_source_failure_asks_for_retry
    with_google(FakeGooglePlay.new({})) do
      notify(subscription(2), bearer: 'keys-down')

      assert_equal(503, last_response.status)
    end
  end

  # 認証の設定を書き忘れたら 503（再送させる）。
  def test_missing_auth_configuration_is_unavailable
    with_google(FakeGooglePlay.new({}), config: {}) do
      notify(subscription(2))

      assert_equal(503, last_response.status)
    end
  end

  def test_without_google_play_is_unavailable
    previous = Relay::BaseApp.settings.google_play
    Relay::BaseApp.set(:google_play, nil)
    notify(subscription(2))

    assert_equal(503, last_response.status)
  ensure
    Relay::BaseApp.set(:google_play, previous)
  end

  def test_malformed_message_is_rejected
    with_google(FakeGooglePlay.new({})) do
      post(
        '/store/google/notifications', {message: {}}.to_json,
        {'CONTENT_TYPE' => 'application/json', 'HTTP_AUTHORIZATION' => 'Bearer good'}
      )

      assert_equal(400, last_response.status)
    end
  end

  # --- POST /store/google/notifications（中身） --------------------------------

  # ⚠ 状態は通知の中身ではなく API から引き直す。
  def test_notification_refreshes_state_from_the_api
    with_google(FakeGooglePlay.new({'token-1' => result('active')})) {purchase}
    fake = FakeGooglePlay.new({'token-1' => result('expired', signed_at: 2)})
    with_google(fake) do
      notify(subscription(13))

      assert_equal(200, last_response.status)
      assert_equal('expired', database.find_entitlement('google', 'token-1')['status'])
      assert_equal(['token-1'], fake.calls)
      assert_equal(1, notification_count('EXPIRED', 'expired'))
    end
  end

  # 返金・取り消しも引き直す。
  def test_voided_purchase_notification_refreshes_state
    with_google(FakeGooglePlay.new({'token-1' => result('active')})) {purchase}
    with_google(FakeGooglePlay.new({'token-1' => result('expired', signed_at: 2)})) do
      notify({'packageName' => PACKAGE, 'voidedPurchaseNotification' => {'purchaseToken' => 'token-1'}})

      assert_equal(200, last_response.status)
      assert_equal('expired', database.find_entitlement('google', 'token-1')['status'])
    end
  end

  # ⚠⚠ Google API に届かないときは 503 ＝ Pub/Sub に再送させる。状態は変えない。
  def test_unavailable_asks_for_retry_and_keeps_state
    with_google(FakeGooglePlay.new({'token-1' => result('active')})) {purchase}
    with_google(FakeGooglePlay.new({'token-1' => :unavailable})) do
      notify(subscription(13))

      assert_equal(503, last_response.status)
      assert_equal('active', database.find_entitlement('google', 'token-1')['status'])
    end
  end

  def test_unknown_purchase_is_ignored
    fake = FakeGooglePlay.new({})
    with_google(fake) do
      notify(subscription(4))

      assert_equal(200, last_response.status)
      assert_empty(fake.calls)
      assert_equal(1, notification_count('PURCHASED', 'unknown_purchase'))
    end
  end

  def test_test_notification_is_acknowledged
    with_google(FakeGooglePlay.new({})) do
      notify({'packageName' => PACKAGE, 'testNotification' => {'version' => '1.0'}})

      assert_equal(200, last_response.status)
      assert_equal(1, notification_count('TEST', 'test'))
    end
  end

  def test_other_package_is_ignored
    with_google(FakeGooglePlay.new({})) do
      notify(subscription(4, package: 'net.shrieker.capsicum.debug'))

      assert_equal(200, last_response.status)
      assert_equal(1, notification_count('PURCHASED', 'other_app'))
    end
  end

  # ⚠ 投げ銭（消耗型）の通知は利用権と関係ないので 200 で受け流す。
  def test_one_time_product_is_ignored
    fake = FakeGooglePlay.new({})
    with_google(fake) do
      notify({'packageName' => PACKAGE, 'oneTimeProductNotification' => {'purchaseToken' => 'tip'}})

      assert_equal(200, last_response.status)
      assert_empty(fake.calls)
      assert_equal(1, notification_count('OTHER', 'no_subscription'))
    end
  end
end
