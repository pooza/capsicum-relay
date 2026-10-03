require_relative 'test_helper'
require 'relay/entitlement_gate'

# 利用権の状態 × 期限の組み合わせ (#63・フェーズ 3)。
#
# ⚠⚠ **ここで固定したいのは 3 点。**
#
# 1. **`active` のまま期限が過ぎた行を通さない** —— 更新の通知を取りこぼすと行は
#    `active` で残るので、`expires_at` を見ないと**永久に通る**（#63 本文の
#    「通知だけに頼ると、取りこぼした購読が永久に有効なまま残る」）
# 2. **未払い（猶予・課金リトライ・支払い保留）は止める**（2026-10-03 pooza 判断）
# 3. **返金済みは支払い済みの期間が残っているあいだだけ通す**（同判断）。
#    ⚠ 期限が読めない返金済みは通さない（無期限の無償になるため）
#
# ⚠ 期限の読めない `active` は **fail-open で通す** —— ストアの応答の形が変わった
# だけで配信が落ちるのを避ける。**守りたいものが返金済みとは逆**なので揃えない。
class EntitlementGatePeriodTest < Minitest::Test
  G = Relay::EntitlementGate

  NOW = Time.utc(2026, 10, 3, 12, 0, 0)
  FUTURE = '2026-11-01 00:00:00'.freeze
  PAST = '2026-09-01 00:00:00'.freeze

  class FakeDatabase
    def initialize(rows) = @rows = rows
    def entitlement_tokens_for_device(_device_id) = @rows
    # 同じ端末の購読先 (#82)。期間の検査ではプリセットを持たない端末として扱う。
    def servers_for_device(_device_id) = []
  end

  ON = {'RELAY_ENTITLEMENT_ENFORCE' => 'true'}.freeze

  def decide(rows)
    return G.decide(
      subscription: {'server' => 'mastodon.social', 'device_id' => 'd1'},
      database: FakeDatabase.new(rows),
      env: ON,
      now: NOW,
    )
  end

  def row(status, expires_at = nil)
    return {'status' => status, 'expires_at' => expires_at}
  end

  # --- active --------------------------------------------------------------

  def test_active_within_period_is_allowed
    assert_equal([true, 'entitled'], decide([row('active', FUTURE)]))
  end

  # ⚠⚠ **#63 の核心。**通知を取りこぼした行がここで止まる。
  def test_active_past_its_expiry_is_denied_as_expired
    assert_equal([false, 'expired'], decide([row('active', PAST)]))
  end

  # ⚠ 期限が分からない有効な購入は通す（fail-open）。確かめ直しの対象になる。
  def test_active_without_expiry_is_allowed
    assert_equal([true, 'entitled'], decide([row('active', nil)]))
    assert_equal([true, 'entitled'], decide([row('active', '')]))
  end

  # ⚠ 読めない値も fail-open（形が変わっただけで止めない）。
  def test_active_with_unparsable_expiry_is_allowed
    assert_equal([true, 'entitled'], decide([row('active', 'not-a-time')]))
  end

  # ⚠⚠ **帯の無い文字列をローカル時刻として読まない。**ストアが入れるのは UTC の
  # `%Y-%m-%d %H:%M:%S`。JST で読むと 9 時間ぶん判定がずれる。
  def test_expiry_without_a_zone_is_read_as_utc
    # NOW の 1 分後（UTC）。JST として読むと 9 時間前になり「期限切れ」に倒れる。
    assert_equal([true, 'entitled'], decide([row('active', '2026-10-03 12:01:00')]))
    # NOW の 1 分前（UTC）。
    assert_equal([false, 'expired'], decide([row('active', '2026-10-03 11:59:00')]))
  end

  def test_expiry_with_an_explicit_zone_is_honored
    assert_equal([true, 'entitled'], decide([row('active', '2026-11-01T00:00:00Z')]))
    assert_equal([false, 'expired'], decide([row('active', '2026-09-01T00:00:00+09:00')]))
  end

  # --- 未払い --------------------------------------------------------------

  def test_unpaid_statuses_are_denied_regardless_of_expiry
    ['grace', 'billing_retry', 'pending'].each do |status|
      assert_equal([false, 'unpaid'], decide([row(status, FUTURE)]), status)
      assert_equal([false, 'unpaid'], decide([row(status, PAST)]), status)
      assert_equal([false, 'unpaid'], decide([row(status, nil)]), status)
    end
  end

  # --- 返金 ----------------------------------------------------------------

  # ⚠ 期限まで通す（2026-10-03 判断）。理由を分けるのは、実質無償で配信している
  # 量が見えるようにするため。
  def test_refunded_within_period_is_allowed_with_its_own_reason
    assert_equal([true, 'entitled_refunded'], decide([row('revoked', FUTURE)]))
  end

  def test_refunded_past_its_expiry_is_denied
    assert_equal([false, 'expired'], decide([row('revoked', PAST)]))
  end

  # ⚠⚠ **返金済み + 期限不明は通さない。**fail-open にすると「期限まで」が無期限に
  # なる。⚠ `active` の同じ形（通す）と**逆向き**なのは意図的。
  def test_refunded_without_a_readable_expiry_is_denied
    assert_equal([false, 'expired'], decide([row('revoked', nil)]))
    assert_equal([false, 'expired'], decide([row('revoked', 'not-a-time')]))
  end

  # --- 複数行・理由の選び方 ------------------------------------------------

  def test_one_allowed_row_is_enough
    assert_equal([true, 'entitled'], decide([row('expired'), row('active', FUTURE)]))
  end

  # ⚠⚠ **未払いを残す。**利用者が自分で直せる唯一の状態で、capsicum#1123 の
  # 登録ステータス画面が案内を出す対象。
  def test_unpaid_is_the_most_informative_denial
    assert_equal(
      [false, 'unpaid'],
      decide([row('expired'), row('unverified'), row('grace')]),
    )
  end

  def test_expired_beats_no_entitlement_as_a_reason
    assert_equal([false, 'expired'], decide([row('unverified'), row('expired')]))
  end

  # ⚠ 上流が status を増やしたときに勝手に通さない（理由は `no_entitlement`）。
  def test_unknown_status_is_not_entitled
    assert_equal([false, 'no_entitlement'], decide([row('something_new', FUTURE)]))
  end

  def test_unverified_is_not_entitled_even_within_period
    assert_equal([false, 'no_entitlement'], decide([row('unverified', FUTURE)]))
  end
end
