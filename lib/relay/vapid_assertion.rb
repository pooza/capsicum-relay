require 'base64'
require 'jwt'
require 'openssl'

module Relay
  # Web Push の `Authorization` ヘッダ（VAPID）を読んで、**署名した鍵**を返す (#69)。
  #
  # ⚠⚠ **これが「サーバー側から検証できる唯一の材料」。**`/register` が受け取る
  # `server` はクライアントの申告で検証できないが、`/push` を叩くのは **fedi
  # サーバー自身**なので、その署名だけは本物かどうかを確かめられる。
  #
  # ⚠ **ここが返すのは「誰が署名したか」だけで、「それがプリセットか」は判定しない。**
  # 鍵とホストの対応は [Relay::VapidKeyDirectory] が持ち、突き合わせは
  # [Relay::EntitlementGate] がする。**3 つを混ぜない** —— 混ぜると
  # 「鍵が引けなかった」と「鍵が違った」が同じ失敗に溶けて、⚠ **前者は
  # こちらの障害・後者は詐称**という正反対の意味が区別できなくなる。
  #
  # 対応する 2 つの形:
  #
  # | | ヘッダ | 公開鍵の在り処 |
  # | --- | --- | --- |
  # | 標準（RFC 8292） | `Authorization: vapid t=<JWT>,k=<公開鍵>` | `k=` |
  # | 旧（draft-01） | `Authorization: WebPush <JWT>` | ⚠ **`Crypto-Key: dh=…;p256ecdsa=<公開鍵>`** |
  #
  # ⚠⚠ **旧形式を落とさないこと。**Mastodon は購読ごとに `standard` 列を持ち、
  # **false の購読には旧形式で送る**（`app/lib/web_push_request.rb`）。旧形式だけ
  # 弾くと、**古い購読を持つ本物のプリセットサーバーが詐称として扱われる。**
  module VapidAssertion
    # P-256 の非圧縮点（`0x04` + X 32 + Y 32）。
    RAW_PUBLIC_KEY_BYTES = 65
    CURVE = 'prime256v1'.freeze
    ALGORITHM = 'ES256'.freeze

    # 検証できた。[public_key] は base64url（パディング無し）に揃えた公開鍵。
    OUTCOME_VERIFIED = 'verified'.freeze
    # ヘッダが無い。⚠ **本物の Mastodon / Misskey は必ず付ける**ので、
    # プリセットを名乗る push にこれが出たら詐称を疑う材料になる。
    OUTCOME_ABSENT = 'absent'.freeze
    # ヘッダはあるが読めない（形式・公開鍵の長さ・alg）。
    OUTCOME_MALFORMED = 'malformed'.freeze
    # 公開鍵は読めたが、その鍵では署名が合わない / 期限切れ。
    OUTCOME_BAD_SIGNATURE = 'bad_signature'.freeze

    Result = Struct.new(:outcome, :public_key, :subject, :audience, keyword_init: true) do
      def verified?
        return outcome == OUTCOME_VERIFIED
      end
    end

    # [authorization] は `Authorization` ヘッダ、[crypto_key] は `Crypto-Key`
    # ヘッダ（旧形式のときだけ要る）。
    #
    # ⚠ **例外を外へ出さない。**受け口は認証なしで叩けるので、壊れたヘッダで
    # 500 になってはいけない（#61 の Codex P2 と同じ理由）。
    def self.verify(authorization:, crypto_key: nil)
      token, encoded_key = extract(authorization, crypto_key)
      return Result.new(outcome: OUTCOME_ABSENT) if token.nil?
      return Result.new(outcome: OUTCOME_MALFORMED) if encoded_key.nil?

      raw = decode_key(encoded_key)
      return Result.new(outcome: OUTCOME_MALFORMED) if raw.nil?

      return decode_token(token, raw, encoded_key)
    rescue StandardError
      return Result.new(outcome: OUTCOME_MALFORMED)
    end

    # `Authorization` の 2 形式から `[JWT, 公開鍵]` を取り出す。
    def self.extract(authorization, crypto_key)
      value = authorization.to_s.strip
      return [nil, nil] if value.empty?

      scheme, rest = value.split(/\s+/, 2)
      case scheme.to_s.downcase
      when 'vapid' then return standard_parts(rest)
      when 'webpush' then return [presence(rest), p256ecdsa(crypto_key)]
      else return [nil, nil]
      end
    end

    # `t=<JWT>,k=<公開鍵>`。⚠ 順序は決まっていないので**キーで引く**。
    # ⚠ 値に `=` が入る（base64 のパディング）ので `split('=')` にしない。
    def self.standard_parts(rest)
      params = rest.to_s.split(',').to_h do |part|
        key, _, value = part.strip.partition('=')
        [key.downcase, value]
      end
      return [presence(params['t']), presence(params['k'])]
    rescue StandardError
      return [nil, nil]
    end

    # `Crypto-Key: dh=…;p256ecdsa=…` から公開鍵だけ取る。
    def self.p256ecdsa(crypto_key)
      crypto_key.to_s.split(/[;,]/).each do |part|
        key, _, value = part.strip.partition('=')
        return presence(value) if key.casecmp?('p256ecdsa')
      end
      return nil
    end

    def self.presence(value)
      stripped = value.to_s.strip
      return stripped.empty? ? nil : stripped
    end

    # ⚠ **長さを見る。**65 バイトでなければ P-256 の非圧縮点ではないので、
    # `OpenSSL` に渡す前に落とす（渡すと例外の種類が環境で変わる）。
    def self.decode_key(encoded)
      raw = Base64.urlsafe_decode64(pad(encoded.tr('+/', '-_')))
      return nil unless raw.bytesize == RAW_PUBLIC_KEY_BYTES
      return nil unless raw.getbyte(0) == 0x04

      return raw
    rescue ArgumentError
      return nil
    end

    def self.pad(encoded)
      stripped = encoded.delete('=')
      return stripped + ('=' * ((4 - (stripped.length % 4)) % 4))
    end

    # ⚠ **`exp` は JWT 側が見る**（`verify_expiration` の既定が true）。
    # Mastodon は 24 時間、Misskey（`web-push`）は 12 時間で切る。
    def self.decode_token(token, raw, encoded_key)
      payload, = JWT.decode(token, public_key_from(raw), true, algorithm: ALGORITHM)
      return Result.new(
        outcome: OUTCOME_VERIFIED,
        public_key: normalize_key(encoded_key),
        subject: payload['sub'],
        audience: payload['aud'],
      )
    rescue JWT::DecodeError
      return Result.new(outcome: OUTCOME_BAD_SIGNATURE)
    end

    # 生の非圧縮点から検証用の EC 公開鍵を組む。
    #
    # ⚠ OpenSSL 3 系では `EC#public_key=` が使えないので、**SPKI の DER を作って
    # 読ませる**。ここを `EC.new(CURVE)` + 代入で書くと動く環境と動かない環境が
    # できる。
    def self.public_key_from(raw)
      asn1 = OpenSSL::ASN1::Sequence(
        [
          OpenSSL::ASN1::Sequence(
            [
              OpenSSL::ASN1::ObjectId('id-ecPublicKey'),
              OpenSSL::ASN1::ObjectId(CURVE),
            ],
          ),
          OpenSSL::ASN1::BitString(raw),
        ],
      )
      return OpenSSL::PKey::EC.new(asn1.to_der)
    end

    # ⚠ **比較する前に形を揃える。**パディングの有無と `+/` / `-_` の違いだけで
    # 同じ鍵が「違う鍵」に見える。サーバーが `/api/v2/instance` で返す形と
    # ヘッダの形が揃っている保証は無い。
    def self.normalize_key(encoded)
      return encoded.to_s.tr('+/', '-_').delete('=')
    end
  end
end
