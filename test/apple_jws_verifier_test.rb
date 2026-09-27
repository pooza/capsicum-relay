require_relative 'test_helper'
require_relative 'support/apple_test_pki'

# #61: Apple が署名した JWS の検証。
#
# ⚠⚠ **通知の受け口は共有シークレットを見ない**ので、ここが唯一の関門になる。
# 「署名が通るもの」だけでなく「通ってはいけないもの」を並べて固定する。
class AppleJwsVerifierTest < Minitest::Test
  PAYLOAD = {'notificationType' => 'DID_RENEW', 'data' => {'bundleId' => 'jp.example'}}.freeze

  def setup
    @pki = AppleTestPki.new
  end

  def test_valid_jws_returns_payload
    assert_equal(PAYLOAD, @pki.verifier.verify(@pki.sign(PAYLOAD)))
  end

  # 同梱のルート（本物の Apple Root CA - G3）では、テストの PKI は通らない。
  def test_bundled_apple_root_rejects_foreign_chain
    assert_raises(Relay::AppleJwsVerifier::Invalid) do
      Relay::AppleJwsVerifier.new.verify(@pki.sign(PAYLOAD))
    end
  end

  # ⚠⚠ 送り手が `x5c` に自前のルートを入れても、信頼の起点にはならない。
  def test_attacker_chain_with_its_own_root_is_rejected
    attacker = AppleTestPki.new

    assert_raises(Relay::AppleJwsVerifier::Invalid) do
      @pki.verifier.verify(attacker.sign(PAYLOAD))
    end
  end

  # 葉の鍵ではない鍵で署名されたもの（証明書は本物・署名だけ偽物）。
  def test_signature_by_another_key_is_rejected
    forged = @pki.sign(PAYLOAD, key: OpenSSL::PKey::EC.generate('prime256v1'))

    assert_raises(Relay::AppleJwsVerifier::Invalid) {@pki.verifier.verify(forged)}
  end

  def test_tampered_payload_is_rejected
    header, _, signature = @pki.sign(PAYLOAD).split('.')
    body = Base64.urlsafe_encode64({'notificationType' => 'REFUND'}.to_json, padding: false)

    assert_raises(Relay::AppleJwsVerifier::Invalid) do
      @pki.verifier.verify([header, body, signature].join('.'))
    end
  end

  def test_leaf_without_app_store_oid_is_rejected
    pki = AppleTestPki.new(leaf_oid: false)

    assert_raises(Relay::AppleJwsVerifier::Invalid) {pki.verifier.verify(pki.sign(PAYLOAD))}
  end

  def test_intermediate_without_apple_oid_is_rejected
    pki = AppleTestPki.new(intermediate_oid: false)

    assert_raises(Relay::AppleJwsVerifier::Invalid) {pki.verifier.verify(pki.sign(PAYLOAD))}
  end

  def test_x5c_with_two_certificates_is_rejected
    jws = @pki.sign(PAYLOAD, x5c: @pki.default_x5c.first(2))

    assert_raises(Relay::AppleJwsVerifier::Invalid) {@pki.verifier.verify(jws)}
  end

  def test_non_es256_is_rejected
    jws = JWT.encode(PAYLOAD, 'secret', 'HS256', {x5c: @pki.default_x5c})

    assert_raises(Relay::AppleJwsVerifier::Invalid) {@pki.verifier.verify(jws)}
  end

  def test_garbage_is_rejected
    assert_raises(Relay::AppleJwsVerifier::Invalid) {@pki.verifier.verify('not-a-jws')}
    assert_raises(Relay::AppleJwsVerifier::Invalid) {@pki.verifier.verify(nil)}
  end

  # 同梱のルートが本物の Apple Root CA - G3 であること（差し替えられていないこと）。
  def test_bundled_root_is_apple_root_ca_g3
    cert = OpenSSL::X509::Certificate.new(File.read(Relay::AppleJwsVerifier::ROOT_CERT_PATH))
    fingerprint = OpenSSL::Digest::SHA256.hexdigest(cert.to_der).upcase

    assert_equal('63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179', fingerprint)
  end
end
