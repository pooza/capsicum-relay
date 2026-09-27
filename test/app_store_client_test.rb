require_relative 'test_helper'
require 'logger'
require 'stringio'
require 'tmpdir'
require 'lib/relay/app_store_client'
require_relative 'support/apple_test_pki'

# #61: App Store Server API でサブスクの状態を引く。
#
# HTTP だけを差し替え（`http:`）、応答の JWS はテストの PKI で本当に署名して
# 検証まで通す。
class AppStoreClientTest < Minitest::Test
  BUNDLE_ID = 'jp.co.b-shock.capsicum'.freeze
  EXPIRES_MS = 1_790_000_000_000

  def setup
    @pki = AppleTestPki.new
    @dir = Dir.mktmpdir
    @key_path = File.join(@dir, 'key.p8')
    File.write(@key_path, OpenSSL::PKey::EC.generate('prime256v1').to_pem)
    @log = StringIO.new
    @calls = []
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def client(responses, environments: ['Production', 'Sandbox'])
    http = lambda do |environment, path, token|
      @calls << [environment, path, token]
      next responses.fetch(environment)
    end
    return Relay::AppStoreClient.new(
      {
        'key_id' => 'KEY', 'issuer_id' => 'ISSUER', 'key_path' => @key_path,
        'bundle_id' => BUNDLE_ID, 'environments' => environments
      },
      logger: Logger.new(@log), verifier: @pki.verifier, http: http,
    )
  end

  def status_body(status:, environment: 'Production', bundle_id: BUNDLE_ID)
    transaction = @pki.sign({
      'bundleId' => bundle_id, 'productId' => 'relay.monthly',
      'originalTransactionId' => '1000', 'expiresDate' => EXPIRES_MS
    })
    return [200, {
      'environment' => environment,
      'data' => [{
        'lastTransactions' => [{
          'originalTransactionId' => '1000', 'status' => status,
          'signedTransactionInfo' => transaction
        }],
      }],
    }.to_json]
  end

  def not_found
    return [404, {'errorCode' => 4_040_010, 'errorMessage' => 'Transaction id not found.'}.to_json]
  end

  def test_active_subscription
    result = client({'Production' => status_body(status: 1)}).subscription_status('2000')

    assert_equal('1000', result.original_transaction_id)
    assert_equal('relay.monthly', result.product_id)
    assert_equal('active', result.status)
    assert_equal(Time.at(EXPIRES_MS / 1000).utc.strftime('%Y-%m-%d %H:%M:%S'), result.expires_at)
    assert_equal('Production', result.environment)
  end

  def test_status_mapping
    {1 => 'active', 2 => 'expired', 3 => 'billing_retry', 4 => 'grace', 5 => 'revoked'}.each do |code, status|
      result = client({'Production' => status_body(status: code)}).subscription_status('2000')

      assert_equal(status, result.status, "Apple status #{code}")
    end
  end

  # ⚠ TestFlight の購入はサンドボックス。Production に無ければ Sandbox を引く。
  def test_falls_back_to_sandbox_when_not_in_production
    responses = {
      'Production' => not_found,
      'Sandbox' => status_body(status: 1, environment: 'Sandbox'),
    }
    result = client(responses).subscription_status('2000')

    assert_equal('Sandbox', result.environment)
    assert_equal(['Production', 'Sandbox'], @calls.map(&:first))
  end

  # ステージングは Sandbox だけを引く。
  def test_staging_reads_sandbox_only
    responses = {'Sandbox' => status_body(status: 1, environment: 'Sandbox')}
    client(responses, environments: ['Sandbox']).subscription_status('2000')

    assert_equal(['Sandbox'], @calls.map(&:first))
  end

  def test_unknown_transaction_is_nil
    assert_nil(client({'Production' => not_found, 'Sandbox' => not_found}).subscription_status('2000'))
  end

  # 「不正な取引 ID」も見つからない扱い（クライアントが送ってきた値そのものが変）。
  def test_invalid_transaction_id_is_nil
    invalid = [400, {'errorCode' => 4_000_006}.to_json]

    assert_nil(client({'Production' => invalid, 'Sandbox' => invalid}).subscription_status('x'))
  end

  # ⚠⚠ 鍵が revoke された。**全購入の検証が止まる**ので error ログを出して Unavailable。
  def test_rejected_key_is_unavailable_and_logged
    assert_raises(Relay::AppStoreClient::Unavailable) do
      client({'Production' => [401, '']}).subscription_status('2000')
    end
    assert_match(/rejected the key/, @log.string)
  end

  # ⚠ 5xx で Sandbox へ流れない（Production の障害をサンドボックス扱いにしない）。
  def test_server_error_is_unavailable_without_falling_back
    assert_raises(Relay::AppStoreClient::Unavailable) do
      client({'Production' => [503, '{}']}).subscription_status('2000')
    end
    assert_equal(['Production'], @calls.map(&:first))
  end

  def test_other_bundle_is_invalid
    assert_raises(Relay::AppleJwsVerifier::Invalid) do
      client({'Production' => status_body(status: 1, bundle_id: 'com.other')}).subscription_status('2000')
    end
  end

  # 応答の JWS も署名を確かめる（TLS の上でも、形が違うものは使わない）。
  def test_response_signed_by_foreign_chain_is_invalid
    foreign = AppleTestPki.new
    body = status_body(status: 1)
    tampered = JSON.parse(body[1])
    tampered['data'][0]['lastTransactions'][0]['signedTransactionInfo'] =
      foreign.sign({'bundleId' => BUNDLE_ID, 'originalTransactionId' => '1000'})

    assert_raises(Relay::AppleJwsVerifier::Invalid) do
      client({'Production' => [200, tampered.to_json]}).subscription_status('2000')
    end
  end

  # 認証トークンは ES256・aud と bid を持つ。
  def test_bearer_token_claims
    client({'Production' => status_body(status: 1)}).subscription_status('2000')
    payload, header = JWT.decode(@calls.first[2], nil, false)

    assert_equal('ES256', header['alg'])
    assert_equal('KEY', header['kid'])
    assert_equal('ISSUER', payload['iss'])
    assert_equal('appstoreconnect-v1', payload['aud'])
    assert_equal(BUNDLE_ID, payload['bid'])
  end

  # 取引 ID は URL に埋めるのでエスケープする。
  def test_transaction_id_is_escaped
    client({'Production' => not_found, 'Sandbox' => not_found}).subscription_status('../x')

    assert_equal('/inApps/v1/subscriptions/..%2Fx', @calls.first[1])
  end

  def test_from_config_without_section_is_nil
    assert_nil(Relay::AppStoreClient.from_config({}, logger: Logger.new(nil), verifier: nil))
  end
end
