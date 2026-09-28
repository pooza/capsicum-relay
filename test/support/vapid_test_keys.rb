require 'base64'
require 'openssl'

# テスト用の **本物の** P-256 公開鍵（base64url・パディング無し）。
#
# ⚠⚠ **`'BOldKey'` のような文字列を鍵として使わないこと。**PR #77 の Codex 8 巡目で
# [Relay::VapidKeyDirectory] が「取ってきた値が P-256 の点として読めるか」まで見る
# ようになったので、**それらしい文字列は本番と同じく捨てられる。**捨てられると
# 「引けなかった」扱いになり、検査が通っても**本番と違う経路を通ってしまう。**
#
# ⚠ 生成は読み込み時に 1 回だけ。`OpenSSL::PKey::EC.generate` は 1 本 1ms 未満。
module VapidTestKeys
  # [count] 本の相異なる公開鍵を base64url で返す。
  def self.generate(count)
    return Array.new(count) {encode(OpenSSL::PKey::EC.generate('prime256v1'))}
  end

  # ⚠ `Crypto-Key` ヘッダと同じ形（非圧縮点・`=` 無し）。
  def self.encode(key)
    return Base64.urlsafe_encode64(key.public_key.to_octet_string(:uncompressed)).delete('=')
  end

  # 65 バイト・`0x04` 始まりだが **曲線上に無い点**。長さと先頭バイトだけを見る
  # 検査では通ってしまう値なので、境界の検査に使う。
  def self.off_curve
    return Base64.urlsafe_encode64("\x04#{'A' * 64}").delete('=')
  end

  # base64url に `-` と `_` の **両方**を含む本物の公開鍵（固定値）。
  #
  # ⚠ 形を揃える検査（標準 base64 の `+/` → `-_`）に使う。⚠⚠ **乱数で生成すると
  # `+/` を 1 つも含まない鍵が出ることがあり、検査が素通りする回ができる。**
  FIXED = 'BAqrdgxZEMfAmDUjMG5xIKx0Ptl7RnpeVeKjLCC-0ph-vLjLt6VMPh5J1kZIB_uBA-LlwuDAw4RRG_A5XSAD1mM'.freeze

  # [FIXED] を **標準 base64（`+/`・パディング有り）**で表した形。
  def self.standard_form
    body = FIXED.tr('-_', '+/')
    return body + ('=' * ((4 - (body.length % 4)) % 4))
  end
end
