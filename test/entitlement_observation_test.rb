require_relative 'test_helper'
require 'relay/entitlement_observation'

# `/register` が見た利用権の状況 (capsicum#597 / #59)。
#
# ⚠⚠ **観測だけ。**見たいのは「非プリセット かつ 利用権なし」の登録がどれだけ
# あるか（フェーズ 3 でゲートを閉じたときに誰が止まるか）。
class EntitlementObservationTest < Minitest::Test
  O = Relay::EntitlementObservation

  def classify(**overrides)
    return O.classify(preset: false, device_tokens: [], claimed: nil,
      device_id: 'device-1', token_sent: false, **overrides)
  end

  # フェーズ 3 で止まる候補そのもの。
  def test_non_preset_without_entitlement
    assert_equal({preset: 'no', entitlement: 'none', token: 'none'}, classify)
  end

  def test_preset_without_entitlement
    assert_equal('yes', classify(preset: true)[:preset])
  end

  def test_entitlement_status_from_device_tokens
    result = classify(device_tokens: [{'status' => 'active'}])

    assert_equal('active', result[:entitlement])
  end

  # ⚠⚠ 1 端末が複数の購入にぶら下がりうる（買い直し・別ストア）ので代表を選ぶ。
  def test_picks_the_most_valid_status
    result = classify(
      device_tokens: [
        {'status' => 'expired'}, {'status' => 'active'}, {'status' => 'revoked'}
      ],
    )

    assert_equal('active', result[:entitlement])
  end

  def test_grace_beats_expired
    result = classify(device_tokens: [{'status' => 'expired'}, {'status' => 'grace'}])

    assert_equal('grace', result[:entitlement])
  end

  # ⚠ `unverified` は `expired` より上だが、**許可を意味しない**（誰でも作れる）。
  def test_unverified_beats_expired_but_is_not_active
    result = classify(device_tokens: [{'status' => 'expired'}, {'status' => 'unverified'}])

    assert_equal('unverified', result[:entitlement])
    refute_equal('active', result[:entitlement])
  end

  # ⚠ 上流が status を増やしたときに「有効に近い」と読まない。
  def test_unknown_status_is_lowest
    result = classify(device_tokens: [{'status' => 'something_new'}, {'status' => 'expired'}])

    assert_equal('expired', result[:entitlement])
  end

  def test_unknown_status_alone_is_reported_as_is
    result = classify(device_tokens: [{'status' => 'something_new'}])

    assert_equal('something_new', result[:entitlement])
  end

  def test_token_not_sent
    assert_equal('none', classify(token_sent: false)[:token])
  end

  # ⚠ 別の relay 向けの token・手で作った値・DB を戻した後。異常の合図。
  def test_token_sent_but_unknown
    assert_equal('unknown', classify(token_sent: true, claimed: nil)[:token])
  end

  def test_token_matches_device
    result = classify(
      token_sent: true, claimed: {'device_id' => 'device-1'}, device_id: 'device-1',
    )

    assert_equal('ok', result[:token])
  end

  # ⚠⚠ ゲートは `subscriptions.device_id` から引くので、この端末はフェーズ 3 で
  # 止まる。token を送れているのに止まる、いちばん分かりにくい形。
  def test_token_belongs_to_another_device
    result = classify(
      token_sent: true, claimed: {'device_id' => 'device-2'}, device_id: 'device-1',
    )

    assert_equal('mismatch', result[:token])
  end

  # ⚠ 旧クライアント（device_id を送らない）は token を持っていても引けない。
  # 両方 nil を「一致」と読まないことを固定する。
  def test_register_without_device_id_is_mismatch
    result = classify(
      token_sent: true, claimed: {'device_id' => 'device-2'}, device_id: nil,
    )

    assert_equal('mismatch', result[:token])
  end
end
