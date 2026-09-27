require 'base64'
require 'jwt'
require 'openssl'
require 'lib/relay/apple_jws_verifier'

# App Store の署名を模したテスト用の PKI (#61)。
#
# Apple と同じ形（ルート → 中間 → 葉・葉と中間に用途 OID）の証明書を毎回作り、
# その葉の鍵で JWS に署名する。**本物のルートの代わりにこのルートを信頼させた
# 検証器**（[verifier]）で、署名検証の道筋をすべて通す。
#
# ⚠ **署名検証そのものは差し替えない。**差し替えるのは「どのルートを信頼するか」だけ。
class AppleTestPki
  attr_reader :root, :intermediate, :leaf, :leaf_key

  def initialize(leaf_oid: true, intermediate_oid: true)
    @root_key = ec_key
    @root = certificate('Test Root', @root_key, signer: [@root_key, nil], authority: true)
    @intermediate_key = ec_key
    @intermediate = certificate(
      'Test Intermediate', @intermediate_key,
      signer: [@root_key, @root], authority: true,
      oid: (Relay::AppleJwsVerifier::INTERMEDIATE_OID if intermediate_oid)
    )
    @leaf_key = ec_key
    @leaf = certificate(
      'Test Leaf', @leaf_key,
      signer: [@intermediate_key, @intermediate], authority: false,
      oid: (Relay::AppleJwsVerifier::LEAF_OID if leaf_oid)
    )
  end

  # このルートだけを信頼する検証器。
  def verifier
    return Relay::AppleJwsVerifier.new(root_certs: [@root])
  end

  # [payload] を葉の鍵で署名した JWS。`x5c` は葉・中間・ルートの 3 枚。
  def sign(payload, key: @leaf_key, x5c: default_x5c)
    return JWT.encode(payload, key, 'ES256', {x5c: x5c})
  end

  def default_x5c
    return [@leaf, @intermediate, @root].map {|cert| Base64.strict_encode64(cert.to_der)}
  end

  private

  def ec_key
    return OpenSSL::PKey::EC.generate('prime256v1')
  end

  # [signer] は `[署名する鍵, 発行者の証明書]`。ルートは発行者なし（自己署名）。
  def certificate(name, key, signer:, authority:, oid: nil)
    signing_key, issuer = signer
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1..(2**32))
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = cert
    extensions.issuer_certificate = issuer || cert
    cert.add_extension(extensions.create_extension('basicConstraints', "CA:#{authority.to_s.upcase}", true))
    cert.add_extension(extensions.create_extension('keyUsage', authority ? 'keyCertSign,cRLSign' : 'digitalSignature', true))
    # Apple の用途 OID。値そのものは検証器が見ないので空の DER（NULL）を入れる。
    cert.add_extension(OpenSSL::X509::Extension.new(oid, OpenSSL::ASN1::Null.new(nil).to_der)) if oid
    cert.sign(signing_key, OpenSSL::Digest.new('SHA256'))
    return cert
  end
end
