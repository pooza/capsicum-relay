require 'base64'
require 'json'
require 'jwt'
require 'openssl'

module Relay
  # Apple が署名した JWS（App Store Server Notifications V2 の `signedPayload`、
  # その中の `signedTransactionInfo` / `signedRenewalInfo`、App Store Server API の
  # 応答に入っている同じ形の値）を検証して中身を返す (#61)。
  #
  # 検証の順:
  #
  # 1. ヘッダの `alg` が ES256 で、`x5c` に 3 枚（葉・中間・ルート）ある
  # 2. ⚠⚠ **葉 → 中間 → 同梱の Apple Root CA - G3** まで証明書チェーンが通る。
  #    `x5c` に入っているルートは**使わない**（送り手が好きな自己署名を入れられる）
  # 3. 葉と中間が Apple の用途 OID を持っている（Apple 公式ライブラリと同じ確認）
  # 4. 葉の公開鍵で署名を検証する
  #
  # ⚠ ルート証明書は `config/apple_root_ca_g3.pem`（2039-04-30 まで有効）。
  # 取得元は https://www.apple.com/certificateauthority/AppleRootCA-G3.cer で、
  # SHA-256 指紋は（2 行に分けて書く）
  # `63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:`
  # `6F:30:17:B3:A8:C4:88:C3:65:3E:91:79`。
  class AppleJwsVerifier
    class Invalid < StandardError; end

    ROOT_CERT_PATH = File.expand_path('../../config/apple_root_ca_g3.pem', __dir__)

    # App Store の署名用の葉証明書が持つ拡張の OID。
    LEAF_OID = '1.2.840.113635.100.6.11.1'.freeze
    # その上の中間証明書（Apple Worldwide Developer Relations - G6 等）が持つ OID。
    INTERMEDIATE_OID = '1.2.840.113635.100.6.2.1'.freeze

    # [root_certs] はテストで自前のルートへ差し替えるための口。
    def initialize(root_certs: [OpenSSL::X509::Certificate.new(File.read(ROOT_CERT_PATH))])
      @root_certs = root_certs
    end

    # 検証済みの payload（Hash）を返す。通らなければ [Invalid] を投げる。
    def verify(jws)
      header = decode_header(jws)
      leaf, intermediate = chain_from(header)
      verify_chain!(leaf, intermediate)
      payload, = JWT.decode(jws, leaf.public_key, true, algorithm: 'ES256')
      return payload
    rescue JWT::DecodeError, OpenSSL::X509::CertificateError, ArgumentError => e
      raise Invalid, "#{e.class}: #{e.message}"
    end

    private

    def decode_header(jws)
      encoded = jws.to_s.split('.').first.to_s
      raise Invalid, 'not a JWS' if encoded.empty?

      header = JSON.parse(Base64.urlsafe_decode64(pad(encoded)))
      # ⚠ 受け口は認証なしで叩ける。`[]` などを渡されて 500 にならないように（Codex P2・PR #75）。
      raise Invalid, 'header is not an object' unless header.is_a?(Hash)
      raise Invalid, "unexpected alg: #{header['alg']}" unless header['alg'] == 'ES256'

      return header
    rescue JSON::ParserError
      raise Invalid, 'header is not JSON'
    end

    def pad(encoded)
      return encoded + ('=' * ((4 - (encoded.length % 4)) % 4))
    end

    # ⚠ `x5c` の 3 枚目（ルート）は読まない。信頼の起点は同梱したルートだけ。
    def chain_from(header)
      x5c = header['x5c']
      raise Invalid, 'x5c must have 3 certificates' unless x5c.is_a?(Array) && x5c.size == 3
      raise Invalid, 'x5c must be strings' unless x5c.all?(String)

      return x5c.first(2).map {|der| OpenSSL::X509::Certificate.new(Base64.strict_decode64(der))}
    end

    def verify_chain!(leaf, intermediate)
      store = OpenSSL::X509::Store.new
      @root_certs.each {|cert| store.add_cert(cert)}
      unless store.verify(leaf, [intermediate])
        raise Invalid, "certificate chain: #{store.error_string}"
      end
      raise Invalid, 'leaf lacks the App Store OID' unless extension?(leaf, LEAF_OID)
      return if extension?(intermediate, INTERMEDIATE_OID)

      raise Invalid, 'intermediate lacks the Apple OID'
    end

    def extension?(cert, oid)
      return cert.extensions.any? {|ext| ext.oid == oid}
    end
  end
end
