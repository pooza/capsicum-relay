require_relative 'test_helper'
require 'logger'
require 'stringio'
require 'lib/relay/google_play_client'

# #62: Google Play Developer API でサブスクの状態を引く。
#
# HTTP・アクセストークン・時計を差し替える（Google への通信はしない）。
class GooglePlayClientTest < Minitest::Test
  PACKAGE = 'net.shrieker.capsicum'.freeze
  NOW = Time.utc(2026, 9, 27, 12, 0, 0)

  def setup
    @log = StringIO.new
    @calls = []
  end

  def client(code, body, token_source: -> {'access-token'})
    http = lambda do |url, token|
      @calls << [url, token]
      next [code, body]
    end
    return Relay::GooglePlayClient.new(
      {'package_name' => PACKAGE, 'service_account_path' => '/nonexistent.json'},
      logger: Logger.new(@log), http: http, token_source: token_source, clock: -> {NOW},
    )
  end

  def purchase(state, expiry: '2026-10-27T12:00:00Z', test: false, items: nil)
    body = {
      'subscriptionState' => state,
      'lineItems' => items || [{'productId' => 'relay.monthly', 'expiryTime' => expiry}],
    }
    body['testPurchase'] = {} if test
    return body.to_json
  end

  def status_of(state, **)
    return client(200, purchase(state, **)).purchase_status('token-1').status
  end

  def test_active_purchase
    result = client(200, purchase('SUBSCRIPTION_STATE_ACTIVE')).purchase_status('token-1')

    assert_equal('token-1', result.purchase_id)
    assert_equal('relay.monthly', result.product_id)
    assert_equal('active', result.status)
    assert_equal('2026-10-27 12:00:00', result.expires_at)
    assert_equal('Production', result.environment)
    # ⚠ 署名時刻を持たないので、問い合わせを始めた時刻を順序に使う。
    assert_equal((NOW.to_f * 1000).to_i, result.signed_at)
  end

  def test_state_mapping
    {
      'SUBSCRIPTION_STATE_IN_GRACE_PERIOD' => 'grace',
      'SUBSCRIPTION_STATE_ON_HOLD' => 'billing_retry',
      'SUBSCRIPTION_STATE_PAUSED' => 'expired',
      'SUBSCRIPTION_STATE_EXPIRED' => 'expired',
      'SUBSCRIPTION_STATE_PENDING' => 'pending',
      'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED' => 'expired',
    }.each {|state, status| assert_equal(status, status_of(state), state)}
  end

  # ⚠ 解約は「自動更新を止めた」だけ。期限までは使える。
  def test_canceled_is_active_until_expiry
    assert_equal('active', status_of('SUBSCRIPTION_STATE_CANCELED', expiry: '2026-10-01T00:00:00Z'))
    assert_equal('expired', status_of('SUBSCRIPTION_STATE_CANCELED', expiry: '2026-09-01T00:00:00Z'))
  end

  def test_unknown_state_is_expired_and_logged
    assert_equal('expired', status_of('SUBSCRIPTION_STATE_SOMETHING_NEW'))
    assert_match(/Unknown Google Play subscription state/, @log.string)
  end

  # ライセンステスターの購入（TestFlight と同じく Sandbox の印）。
  def test_license_tester_purchase_is_marked_sandbox
    result = client(200, purchase('SUBSCRIPTION_STATE_ACTIVE', test: true)).purchase_status('t')

    assert_equal('Sandbox', result.environment)
  end

  # 項目が複数あれば、いちばん先まで有効なものの期限を採る。
  def test_latest_line_item_wins
    items = [
      {'productId' => 'relay.monthly', 'expiryTime' => '2026-09-30T00:00:00Z'},
      {'productId' => 'relay.monthly', 'expiryTime' => '2026-10-30T00:00:00Z'},
    ]
    result = client(200, purchase('SUBSCRIPTION_STATE_ACTIVE', items: items)).purchase_status('t')

    assert_equal('2026-10-30 00:00:00', result.expires_at)
  end

  def test_unknown_token_is_nil
    [400, 404, 410].each do |code|
      assert_nil(client(code, '{}').purchase_status('t'), "HTTP #{code}")
    end
  end

  # ⚠⚠ 権限が無い・外された。**全購入の検証が止まる**ので error ログを出して Unavailable。
  def test_permission_denied_is_unavailable_and_logged
    [401, 403].each do |code|
      assert_raises(Relay::GooglePlayClient::Unavailable) {client(code, '{}').purchase_status('t')}
    end
    assert_match(/rejected the service account/, @log.string)
  end

  def test_server_error_is_unavailable
    assert_raises(Relay::StoreUnavailable) {client(503, '{}').purchase_status('t')}
  end

  # アクセストークンが取れない（Google の認証サーバーに届かない等）も fail-open 側。
  def test_token_failure_is_unavailable
    failing = client(200, '{}', token_source: -> {raise 'oauth down'})

    assert_raises(Relay::GooglePlayClient::Unavailable) {failing.purchase_status('t')}
  end

  def test_non_json_response_is_invalid
    assert_raises(Relay::StoreResponseInvalid) {client(200, '<html>').purchase_status('t')}
    assert_raises(Relay::StoreResponseInvalid) {client(200, '[]').purchase_status('t')}
  end

  # ⚠ 名前解決の失敗（SocketError）も Unavailable（`.invalid` は解決できない予約 TLD）。
  def test_dns_failure_is_unavailable
    assert_raises(Relay::GooglePlayClient::Unavailable) do
      client(200, '{}').send(:request, 'https://play.invalid/x', 'token')
    end
  end

  def test_url_and_bearer
    client(200, purchase('SUBSCRIPTION_STATE_ACTIVE')).purchase_status('a/b c')
    url, token = @calls.first

    assert_equal(
      'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/' \
        'net.shrieker.capsicum/purchases/subscriptionsv2/tokens/a%2Fb%20c',
      url,
    )
    assert_equal('access-token', token)
  end

  def test_from_config_without_section_is_nil
    assert_nil(Relay::GooglePlayClient.from_config({}, logger: Logger.new(nil)))
  end
end
