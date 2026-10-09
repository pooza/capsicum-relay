require_relative 'test_helper'
require 'lib/relay/push_outcome'

# 成功した push の行に、配送先が振った識別子が載る (#85)。
#
# ⚠⚠ **これが無いと「relay は投げた、端末には出ない」を追えない。**APNs は受理
# した時点で 200 を返すので、relay から見えるのはそこまで。その先（端末への
# 配送・破棄の理由）は Apple の Push Notification Console を `apns-id` で引く。
class PushOutcomeDetailTest < Minitest::Test
  def test_apns_success_carries_apns_id
    detail = Relay::PushOutcome.detail({success: true, id: 'A1B2-C3D4'})

    assert_equal({apns_id: 'A1B2-C3D4'}, detail)
  end

  def test_fcm_success_carries_message_name
    detail = Relay::PushOutcome.detail(
      {success: true, name: 'projects/capsicum/messages/0:123'},
    )

    assert_equal({fcm_name: 'projects/capsicum/messages/0:123'}, detail)
  end

  def test_wns_success_carries_msg_id_alongside_status
    detail = Relay::PushOutcome.detail(
      {success: true, status: 200, wns_status: 'received', msg_id: '5C3F'},
    )

    assert_equal({status: 200, wns_status: 'received', wns_msg_id: '5C3F'}, detail)
  end

  # ⚠ 識別子が取れなかった回（ヘッダ欠落）でキーだけ残さない。
  def test_missing_ids_are_omitted
    detail = Relay::PushOutcome.detail({success: true, id: nil})

    assert_empty(detail)
  end

  # 失敗側の項目は従来どおり。
  def test_failure_detail_is_unchanged
    detail = Relay::PushOutcome.detail(
      {success: false, status: 410, reason: 'Unregistered', permanent: true},
    )

    assert_equal({status: 410, reason: 'Unregistered'}, detail)
  end

  # ⚠ 生のレスポンスや接続の情報は載せない。
  def test_unrelated_keys_are_not_copied
    detail = Relay::PushOutcome.detail(
      {success: true, id: 'X', conn: 'reused', body: '{"secret":1}', degraded: true},
    )

    assert_equal({apns_id: 'X'}, detail)
  end

  def test_non_hash_result_is_empty
    assert_empty(Relay::PushOutcome.detail(nil))
  end
end
