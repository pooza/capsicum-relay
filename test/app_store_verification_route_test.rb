require_relative 'support/request_test_case'
require_relative 'support/apple_test_pki'

# #61: Apple の購入の検証。入口は `POST /entitlements` と
# `POST /store/apple/notifications` の 2 つ。
#
# App Store Server API は偽物（[FakeAppStore]）に差し替え、通知の署名はテストの
# PKI で本当に署名して検証まで通す。
class AppStoreVerificationRouteTest < RequestTestCase
  BUNDLE_ID = 'jp.co.b-shock.capsicum'.freeze
  DEVICE = 'device-install-1'.freeze

  # App Store Server API の偽物。取引 ID ごとに結果を決めておく。
  class FakeAppStore
    attr_reader :bundle_id, :calls

    def initialize(results)
      @bundle_id = BUNDLE_ID
      @results = results
      @calls = []
    end

    def purchase_status(transaction_id)
      @calls << transaction_id
      result = @results[transaction_id]
      raise Relay::AppStoreClient::Unavailable, 'down' if result == :unavailable
      raise Relay::AppleJwsVerifier::Invalid, 'bad' if result == :invalid

      return result
    end
  end

  def setup
    super
    @pki = AppleTestPki.new
  end

  def result(status, environment: 'Production', original: '1000')
    return Relay::AppStoreClient::Result.new(
      original_transaction_id: original, product_id: 'relay.monthly', status: status,
      expires_at: '2026-10-27 00:00:00', environment: environment
    )
  end

  def with_app_store(fake)
    previous = [Relay::BaseApp.settings.app_store, Relay::BaseApp.settings.apple_jws_verifier]
    Relay::BaseApp.set(:app_store, fake)
    Relay::BaseApp.set(:apple_jws_verifier, @pki.verifier)
    yield
  ensure
    Relay::BaseApp.set(:app_store, previous[0])
    Relay::BaseApp.set(:apple_jws_verifier, previous[1])
  end

  def purchase(transaction_id, device_id: DEVICE, store: 'apple')
    post_json(
      '/entitlements',
      {store: store, purchase_id: transaction_id, product_id: 'relay.monthly', device_id: device_id},
    )
    return json_response
  end

  def verify_count(outcome)
    return Relay::App.settings.metrics.value(
      'relay_entitlement_verify_total', {store: 'apple', outcome: outcome}
    )
  end

  # --- POST /entitlements ------------------------------------------------------

  # ⚠⚠ 送ってきた transactionId ではなく、元の取引 ID で保存する（更新のたびに
  # transactionId は変わる）。
  def test_verified_purchase_is_active_and_keyed_by_original_transaction
    with_app_store(FakeAppStore.new({'2000' => result('active')})) do
      body = purchase('2000')

      assert_equal(201, last_response.status)
      assert_equal('active', body['status'])
      assert_equal('1000', body['purchase_id'])
      assert_equal('Production', body['environment'])
      assert(database.find_entitlement('apple', '1000'))
      assert_nil(database.find_entitlement('apple', '2000'))
      assert_equal(1, verify_count('active'))
    end
  end

  # ⚠⚠ #89: 前景の枠が埋まっている回は、**何も保存せずに** 503 で断る
  # （PR #90 の Codex P1・行を作ってから返すと、でたらめな行を SQLite の速さで積める）。
  def test_purchase_is_refused_without_a_row_when_the_foreground_slot_is_busy
    fake = FakeAppStore.new({'2000' => result('active')})
    busy = Relay::StoreVerification::FOREGROUND
    with_app_store(fake) do
      busy[:busy] = Relay::StoreVerification.foreground_limit
      body = purchase('2000')

      assert_equal(503, last_response.status)
      assert_equal('verification_busy', body['reason'])
      assert_equal('2', last_response.headers['Retry-After'])
      assert_empty(fake.calls)
      assert_equal(0, database.entitlement_count, '断ったのに行が残っている')
      assert_equal(0, database.entitlement_token_count)
      assert_equal(1, verify_count('busy'))
      assert_equal(Relay::StoreVerification.foreground_limit, busy[:busy], '取っていない枠を返した')
    ensure
      busy[:busy] = 0
    end
  end

  # 枠は、確かめ終わったら返す（成功した回も、例外で抜けた回も）。
  def test_foreground_slot_is_returned_after_each_purchase
    fake = FakeAppStore.new({'2000' => result('active'), '3000' => :unavailable})
    with_app_store(fake) do
      purchase('2000')
      purchase('3000', device_id: 'device-install-2')
      fake.define_singleton_method(:purchase_status) {|_| raise(ArgumentError, 'boom')}
      post_json('/entitlements', {store: 'apple', purchase_id: '4000', device_id: 'device-3'})

      assert_equal(500, last_response.status)
      assert_equal(0, Relay::StoreVerification::FOREGROUND[:busy])
    end
  end

  # スレッドが 1 本の構成では、前景で確かめずに行だけ残す（断ると登録の道が無くなる）。
  def test_single_thread_configuration_defers_verification
    previous = ENV.fetch('PUMA_THREADS', nil)
    ENV['PUMA_THREADS'] = '1'
    fake = FakeAppStore.new({'2000' => result('active')})
    with_app_store(fake) do
      body = purchase('2000')

      assert_equal(201, last_response.status)
      assert_equal('unverified', body['status'])
      assert_empty(fake.calls)
      assert_equal(1, verify_count('deferred'))
    end
  ensure
    ENV['PUMA_THREADS'] = previous
  end

  # TestFlight の購入（2026-09-27 の決定で本番でも有効・印を付ける）。
  def test_sandbox_purchase_is_active_with_environment_mark
    with_app_store(FakeAppStore.new({'2000' => result('active', environment: 'Sandbox')})) do
      body = purchase('2000')

      assert_equal('active', body['status'])
      assert_equal('Sandbox', body['environment'])
    end
  end

  # 別の端末が、更新後の取引 ID で送ってきた → 同じ購入の行へ寄る。
  def test_other_device_with_renewed_transaction_joins_the_same_purchase
    fake = FakeAppStore.new({'2000' => result('active'), '3000' => result('active')})
    with_app_store(fake) do
      purchase('2000')
      purchase('3000', device_id: 'device-install-2')

      assert_equal(1, database.entitlement_count)
      assert_equal(2, database.entitlement_tokens_for_purchase('apple', '1000').size)
    end
  end

  # ⚠ 同じ端末が更新後の取引 ID で送り直した → 行は 1 つのまま、**最初の token を返す**。
  def test_same_device_resending_after_renewal_keeps_its_token
    fake = FakeAppStore.new({'2000' => result('active'), '3000' => result('active')})
    with_app_store(fake) do
      first = purchase('2000')['token']
      second = purchase('3000')['token']

      assert_equal(first, second)
      assert_equal(1, database.entitlement_count)
      assert_equal(1, database.entitlement_token_count)
    end
  end

  # ⚠⚠ fail-open。Apple に届かなくても 201 で返し、`unverified` のまま残す。
  def test_unavailable_keeps_unverified
    with_app_store(FakeAppStore.new({'2000' => :unavailable})) do
      body = purchase('2000')

      assert_equal(201, last_response.status)
      assert_equal('unverified', body['status'])
      assert_equal('2000', body['purchase_id'])
      assert_equal(1, verify_count('unavailable'))
    end
  end

  # ⚠⚠ 一度 active になった購入を「確かめられなかった」で落とさない。
  def test_unavailable_does_not_downgrade_an_active_purchase
    fake = FakeAppStore.new({'2000' => result('active')})
    with_app_store(fake) {purchase('2000')}
    with_app_store(FakeAppStore.new({'1000' => :unavailable})) do
      body = purchase('1000')

      assert_equal('active', body['status'])
    end
  end

  def test_unknown_transaction_stays_unverified
    with_app_store(FakeAppStore.new({})) do
      assert_equal('unverified', purchase('2000')['status'])
      assert_equal(1, verify_count('not_found'))
    end
  end

  def test_invalid_response_stays_unverified
    with_app_store(FakeAppStore.new({'2000' => :invalid})) do
      assert_equal('unverified', purchase('2000')['status'])
      assert_equal(1, verify_count('invalid'))
    end
  end

  # Google / Microsoft は #62 以降。Apple の API を引かない。
  def test_other_store_is_not_sent_to_apple
    fake = FakeAppStore.new({})
    with_app_store(fake) do
      assert_equal('unverified', purchase('gpa.1', store: 'google')['status'])
      assert_empty(fake.calls)
    end
  end

  # --- POST /store/apple/notifications ------------------------------------------

  def notify(payload, pki: @pki)
    post(
      '/store/apple/notifications',
      {signedPayload: pki.sign(payload)}.to_json,
      {'CONTENT_TYPE' => 'application/json'},
    )
  end

  def notification(type, original: '1000', transaction: '9999', bundle_id: BUNDLE_ID, pki: @pki)
    return {
      'notificationType' => type,
      'data' => {
        'bundleId' => bundle_id,
        'environment' => 'Production',
        'signedTransactionInfo' => pki.sign(
          {'originalTransactionId' => original, 'transactionId' => transaction},
        ),
      },
    }
  end

  def notification_count(type, outcome)
    return Relay::App.settings.metrics.value(
      'relay_store_notification_total', {store: 'apple', type: type, outcome: outcome}
    )
  end

  # ⚠ 状態は通知の中身ではなく API から引き直す（通知は EXPIRED と言っていないが、
  # API が expired を返せば expired になる）。
  def test_notification_refreshes_state_from_the_api
    with_app_store(FakeAppStore.new({'2000' => result('active')})) {purchase('2000')}
    fake = FakeAppStore.new({'1000' => result('expired')})
    with_app_store(fake) do
      notify(notification('DID_CHANGE_RENEWAL_STATUS'))

      assert_equal(200, last_response.status)
      assert_equal('expired', database.find_entitlement('apple', '1000')['status'])
      assert_equal(['1000'], fake.calls)
      assert_equal(1, notification_count('DID_CHANGE_RENEWAL_STATUS', 'expired'))
    end
  end

  # ⚠⚠ 登録時に Apple へ届かず、送られた transactionId のまま `unverified` で残った
  # 購入。初回購入の通知はその transactionId を持って来るので、そちらでも引いて
  # 確かめ直す（Codex P1・PR #75）。
  def test_notification_finds_purchase_left_unverified_by_its_transaction_id
    with_app_store(FakeAppStore.new({'2000' => :unavailable})) {purchase('2000')}
    fake = FakeAppStore.new({'1000' => result('active')})
    with_app_store(fake) do
      notify(notification('SUBSCRIBED', transaction: '2000'))

      assert_equal(200, last_response.status)
      assert_equal('active', database.find_entitlement('apple', '1000')['status'])
      assert_nil(database.find_entitlement('apple', '2000'))
    end
  end

  # ⚠⚠ Apple API に届かないときは 503 ＝ Apple に再送させる。状態は変えない。
  def test_notification_asks_for_retry_when_api_is_unavailable
    with_app_store(FakeAppStore.new({'2000' => result('active')})) {purchase('2000')}
    with_app_store(FakeAppStore.new({'1000' => :unavailable})) do
      notify(notification('EXPIRED'))

      assert_equal(503, last_response.status)
      assert_equal('active', database.find_entitlement('apple', '1000')['status'])
    end
  end

  # 知らない購入の通知は 200 で捨てる（API も引かない）。
  def test_notification_for_unknown_purchase_is_ignored
    fake = FakeAppStore.new({})
    with_app_store(fake) do
      notify(notification('SUBSCRIBED'))

      assert_equal(200, last_response.status)
      assert_empty(fake.calls)
      assert_equal(1, notification_count('SUBSCRIBED', 'unknown_purchase'))
    end
  end

  def test_test_notification_is_acknowledged
    fake = FakeAppStore.new({})
    with_app_store(fake) do
      notify({'notificationType' => 'TEST', 'data' => {'bundleId' => BUNDLE_ID}})

      assert_equal(200, last_response.status)
      assert_equal(1, notification_count('TEST', 'test'))
    end
  end

  def test_notification_for_another_app_is_ignored
    with_app_store(FakeAppStore.new({})) do
      notify(notification('SUBSCRIBED', bundle_id: 'com.other'))

      assert_equal(200, last_response.status)
      assert_equal(1, notification_count('SUBSCRIBED', 'other_app'))
    end
  end

  # ⚠⚠ 共有シークレットを見ない入口なので、署名が唯一の関門。
  def test_notification_signed_by_foreign_chain_is_rejected
    with_app_store(FakeAppStore.new({})) do
      notify(notification('REFUND'), pki: AppleTestPki.new)

      assert_equal(400, last_response.status)
      assert_equal(1, notification_count('unknown', 'invalid'))
    end
  end

  # 外側が通っても、中の取引情報だけ差し替えられていれば拒む。
  def test_notification_with_foreign_transaction_info_is_rejected
    with_app_store(FakeAppStore.new({})) do
      notify(notification('REFUND', pki: AppleTestPki.new))

      assert_equal(400, last_response.status)
    end
  end

  def test_notification_without_signed_payload_is_rejected
    with_app_store(FakeAppStore.new({})) do
      post('/store/apple/notifications', {}.to_json, {'CONTENT_TYPE' => 'application/json'})

      assert_equal(400, last_response.status)
    end
  end

  # 設定が無ければ 503（Apple は再送する＝設定を入れた後に取りこぼさない）。
  def test_notification_without_configuration_is_unavailable
    previous = Relay::BaseApp.settings.app_store
    Relay::BaseApp.set(:app_store, nil)
    notify(notification('SUBSCRIBED'))

    assert_equal(503, last_response.status)
  ensure
    Relay::BaseApp.set(:app_store, previous)
  end
end
