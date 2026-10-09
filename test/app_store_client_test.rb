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
        'bundle_id' => BUNDLE_ID, 'environments' => environments,
        'product_ids' => ['relay.monthly']
      },
      logger: Logger.new(@log), verifier: @pki.verifier, http: http,
    )
  end

  def status_body(status:, environment: 'Production', bundle_id: BUNDLE_ID)
    transaction = @pki.sign({
      'bundleId' => bundle_id, 'productId' => 'relay.monthly',
      'originalTransactionId' => '1000', 'expiresDate' => EXPIRES_MS,
      'signedDate' => 1_790_000_000_123
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

  # #89 用: 複数のサブスクグループを持つ応答。[entries] は `[商品, 状態, 期限]`。
  def groups_body(*entries)
    data = entries.each_with_index.map do |(product, status, expires), index|
      original = (1000 + index).to_s
      transaction = @pki.sign({
        'bundleId' => BUNDLE_ID, 'productId' => product, 'originalTransactionId' => original,
        'expiresDate' => expires, 'signedDate' => 1_790_000_000_123
      })
      {'lastTransactions' => [{
        'originalTransactionId' => original, 'status' => status,
        'signedTransactionInfo' => transaction
      }]}
    end
    return [200, {'environment' => 'Production', 'data' => data}.to_json]
  end

  # ⚠⚠ #89: アプリの別のサブスクの購入では、利用権にならない。
  # ⚠ #93: 「知らない購入」（nil）とは分けて、専用の例外で知らせる。
  def test_other_product_is_not_an_entitlement
    body = groups_body(['other.yearly', 1, EXPIRES_MS])

    assert_raises(Relay::StoreProductMismatch) do
      client({'Production' => body}).subscription_status('2000')
    end
    assert_match(/not a relay entitlement product: other\.yearly/, @log.string)
  end

  # ⚠⚠ #93: 無関係なグループの 1 件が検証に落ちても、利用権の商品は返す。
  # `productId` は署名の中にあるので、商品で絞る前に全件を検証するしかない。
  def test_unrelated_invalid_transaction_does_not_hide_the_entitlement
    body = with_broken_group(groups_body(['relay.monthly', 1, EXPIRES_MS]))
    result = client({'Production' => body}).subscription_status('2000')

    assert_equal('active', result.status)
    assert_equal('relay.monthly', result.product_id)
    assert_match(/failed verification \(skipped\)/, @log.string)
  end

  # ⚠⚠ #93: 検証に落ちた件があって一致が 0 件なら、「無い」とも「別の商品」とも
  # 言わない（落ちた 1 件が利用権の取引だったかもしれない）。
  def test_invalid_transaction_with_no_match_is_invalid_not_missing
    body = with_broken_group(groups_body(['other.yearly', 1, EXPIRES_MS]))

    assert_raises(Relay::StoreResponseInvalid) do
      client({'Production' => body}).subscription_status('2000')
    end
  end

  # ⚠⚠ PR #94 の Codex P1: 一致した取引が有効でないとき、検証に落ちた件が残って
  # いれば「失効」と言い切らない。落ちた 1 件が、いま有効な利用権かもしれない
  # （`productId` は署名の中なので、無関係だと確かめる手段が無い）。失効と記録
  # すると、次の `/push` が 410 を返して上流が購読を消す。
  def test_invalid_transaction_beside_an_expired_match_is_invalid_not_expired
    [2, 3, 5].each do |status|
      body = with_broken_group(groups_body(['relay.monthly', status, EXPIRES_MS]))

      assert_raises(Relay::StoreResponseInvalid, "status=#{status}") do
        client({'Production' => body}).subscription_status('2000')
      end
    end
  end

  # 前提: 検証に落ちた件が無ければ、有効でない一致はそのまま返す（従来どおり）。
  def test_expired_match_without_rejections_is_reported_as_expired
    body = groups_body(['relay.monthly', 2, EXPIRES_MS])

    assert_equal('expired', client({'Production' => body}).subscription_status('2000').status)
  end

  # 応答に、署名の壊れた取引を 1 件持つグループを足す。
  def with_broken_group(response)
    code, body = response
    json = JSON.parse(body)
    json['data'] << {'lastTransactions' => [{
      'originalTransactionId' => '9999', 'status' => 1,
      'signedTransactionInfo' => 'not-a-jws'
    }]}
    return [code, json.to_json]
  end

  # ⚠⚠ #89: 別グループの失効した購読が先頭に来ても、利用権の商品の状態を返す。
  def test_entitlement_product_is_picked_over_an_expired_other_group
    body = groups_body(['other.yearly', 2, EXPIRES_MS - 1], ['relay.monthly', 1, EXPIRES_MS])
    result = client({'Production' => body}).subscription_status('2000')

    assert_equal('active', result.status)
    assert_equal('relay.monthly', result.product_id)
    assert_equal('1001', result.original_transaction_id)
  end

  # 利用権の商品が複数あれば、有効なもの → 期限の遅いものを取る。
  def test_active_entitlement_wins_over_an_expired_one
    body = groups_body(['relay.monthly', 2, EXPIRES_MS + 1000], ['relay.monthly', 1, EXPIRES_MS])

    assert_equal('1001', client({'Production' => body}).subscription_status('2000')
      .original_transaction_id)
  end

  # 設定に `product_ids` が無ければ、既定の商品だけを利用権として扱う。
  def test_default_product_ids
    assert_equal(['supporter.relay.monthly'], Relay::EntitlementProducts.from({}))
    assert_equal(['supporter.relay.monthly'], Relay::EntitlementProducts.from({'product_ids' => []}))
    assert_equal(['a'], Relay::EntitlementProducts.from({'product_ids' => ['a', '']}))
  end

  def test_active_subscription
    result = client({'Production' => status_body(status: 1)}).subscription_status('2000')

    assert_equal('1000', result.original_transaction_id)
    assert_equal('relay.monthly', result.product_id)
    assert_equal('active', result.status)
    assert_equal(Time.at(EXPIRES_MS / 1000).utc.strftime('%Y-%m-%d %H:%M:%S'), result.expires_at)
    assert_equal('Production', result.environment)
    assert_equal(1_790_000_000_123, result.signed_at)
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

  # ⚠ 名前解決の失敗（SocketError）も fail-open に倒す（Codex P1・PR #75）。
  # SystemCallError ではないので、拾い漏れると 500 になる。
  def test_dns_failure_is_unavailable
    # `.invalid` は名前解決できないことが予約されている TLD（RFC 2606）。
    client = Relay::AppStoreClient.new(
      {'key_id' => 'KEY', 'issuer_id' => 'ISSUER', 'key_path' => @key_path, 'bundle_id' => BUNDLE_ID},
      logger: Logger.new(@log), verifier: @pki.verifier,
      hosts: {'Production' => 'app-store.invalid', 'Sandbox' => 'app-store.invalid'}
    )

    assert_raises(Relay::AppStoreClient::Unavailable) {client.subscription_status('2000')}
  end

  def test_from_config_without_section_is_nil
    assert_nil(Relay::AppStoreClient.from_config({}, logger: Logger.new(nil), verifier: nil))
  end
end
