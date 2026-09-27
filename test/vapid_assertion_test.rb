require_relative 'test_helper'
require 'base64'
require 'jwt'
require 'openssl'
require 'relay/vapid_assertion'

# Web Push の VAPID `Authorization` ヘッダの検証 (capsicum#597 / #69)。
#
# ⚠⚠ **ここで固定したいのは 3 点。**
#
# 1. **本物の署名だけが `verified`** になる（別の鍵で署名したものは通らない）
# 2. ⚠ **旧形式（`WebPush` + `Crypto-Key`）も読める** —— Mastodon は `standard`
#    が false の購読へ旧形式で送るので、落とすと**本物が詐称扱いになる**
# 3. ⚠ **壊れた入力で例外を出さない**（受け口は認証なしで叩ける）
class VapidAssertionTest < Minitest::Test
  V = Relay::VapidAssertion

  AUDIENCE = 'https://relay.capsicum.shrieker.net'.freeze

  def setup
    @key = OpenSSL::PKey::EC.generate('prime256v1')
    @encoded = encode_key(@key)
  end

  def encode_key(key)
    return Base64.urlsafe_encode64(key.public_key.to_octet_string(:uncompressed)).delete('=')
  end

  def token(key: @key, exp: Time.now.to_i + 3600, sub: 'mailto:ops@example.test')
    return JWT.encode({aud: AUDIENCE, exp: exp, sub: sub}, key, 'ES256', typ: 'JWT')
  end

  # --- 標準形式（RFC 8292） -----------------------------------------------

  def test_verifies_a_standard_header
    result = V.verify(authorization: "vapid t=#{token},k=#{@encoded}")

    assert_predicate(result, :verified?)
    assert_equal(@encoded, result.public_key)
    assert_equal(AUDIENCE, result.audience)
    assert_equal('mailto:ops@example.test', result.subject)
  end

  # ⚠ 並びは決まっていない。`k=` が先でも読めること。
  def test_accepts_the_parameters_in_either_order
    assert_predicate(V.verify(authorization: "vapid k=#{@encoded}, t=#{token}"), :verified?)
  end

  # ⚠ スキームの大小を問わない（`Vapid` を送る実装がある）。
  def test_scheme_is_case_insensitive
    assert_predicate(V.verify(authorization: "VAPID t=#{token},k=#{@encoded}"), :verified?)
  end

  # --- 旧形式（draft-01 / Mastodon の legacy 購読） -------------------------

  # ⚠⚠ **これを落とすと本物のプリセットが詐称扱いになる。**
  def test_verifies_a_legacy_header_with_crypto_key
    result = V.verify(
      authorization: "WebPush #{token}",
      crypto_key: "dh=BOGUSdhvalue;p256ecdsa=#{@encoded}",
    )

    assert_predicate(result, :verified?)
    assert_equal(@encoded, result.public_key)
  end

  def test_legacy_without_crypto_key_is_malformed
    assert_equal(V::OUTCOME_MALFORMED, V.verify(authorization: "WebPush #{token}").outcome)
  end

  # --- 詐称・壊れた入力 ---------------------------------------------------

  # ⚠⚠ **いちばん大事な検査。**別の鍵で署名したものは通らない。
  def test_a_signature_from_another_key_does_not_verify
    other = OpenSSL::PKey::EC.generate('prime256v1')
    result = V.verify(authorization: "vapid t=#{token(key: other)},k=#{@encoded}")

    assert_equal(V::OUTCOME_BAD_SIGNATURE, result.outcome)
    assert_nil(result.public_key)
  end

  def test_expired_tokens_do_not_verify
    result = V.verify(authorization: "vapid t=#{token(exp: Time.now.to_i - 60)},k=#{@encoded}")

    assert_equal(V::OUTCOME_BAD_SIGNATURE, result.outcome)
  end

  def test_missing_header_is_absent
    assert_equal(V::OUTCOME_ABSENT, V.verify(authorization: nil).outcome)
    assert_equal(V::OUTCOME_ABSENT, V.verify(authorization: '   ').outcome)
  end

  def test_unknown_scheme_is_absent
    assert_equal(V::OUTCOME_ABSENT, V.verify(authorization: "Bearer #{token}").outcome)
  end

  # ⚠ **例外を外へ出さない**（500 にしない）。
  def test_broken_input_never_raises
    [
      'vapid',
      'vapid t=,k=',
      "vapid t=#{token}",
      "vapid t=not-a-jwt,k=#{@encoded}",
      'vapid t=a.b.c,k=%%%',
      "vapid t=#{token},k=#{Base64.urlsafe_encode64('short').delete('=')}",
    ].each do |header|
      result = V.verify(authorization: header)

      refute_predicate(result, :verified?, "unexpectedly verified: #{header}")
    end
  end

  # ⚠ 圧縮点（先頭が 0x02 / 0x03）は受けない。長さだけ見ていると通る。
  def test_rejects_a_key_that_is_not_an_uncompressed_point
    compressed = "\x02#{@key.public_key.to_octet_string(:uncompressed)[1, 64]}"
    encoded = Base64.urlsafe_encode64(compressed).delete('=')

    refute_predicate(V.verify(authorization: "vapid t=#{token},k=#{encoded}"), :verified?)
  end

  # --- 比較のための正規化 -------------------------------------------------

  # ⚠⚠ **パディングと `+/` の違いだけで「別の鍵」に見えてはいけない。**
  # サーバーが `/api/v2/instance` で返す形とヘッダの形が揃う保証は無い。
  def test_normalizes_the_key_for_comparison
    standard = Base64.strict_encode64(@key.public_key.to_octet_string(:uncompressed))
    result = V.verify(authorization: "vapid t=#{token},k=#{standard}")

    assert_predicate(result, :verified?)
    assert_equal(@encoded, result.public_key)
    assert_equal(@encoded, V.normalize_key(standard))
  end
end
