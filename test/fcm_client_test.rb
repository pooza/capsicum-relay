require_relative 'test_helper'
require 'lib/relay/fcm_client'

# #71: FCM の 4KB 超過を oversized と判定する。
#
# ⚠ 判定の文字列が FCM の実際の応答とずれて、本番で一度も当たっていなかった。
# 本文は 2026-09-27 に本番の journald で観測したものをそのまま使う。
class FcmClientTest < Minitest::Test
  def fcm_error(message, code: 'INVALID_ARGUMENT')
    return JSON.generate(
      'error' => {
        'code' => 400,
        'message' => message,
        'status' => code,
        'details' => [
          {'@type' => 'type.googleapis.com/google.firebase.fcm.v1.FcmError', 'errorCode' => code},
        ],
      },
    )
  end

  # 2026-09 の本番で返っていた文言。
  def test_current_too_large_message_is_oversized
    body = fcm_error('Message is too large. The maximum is 4K (4096 bytes).')

    assert(Relay::FcmClient.oversized_response?('400', body))
  end

  # #9 の時点の文言も引き続き拾う。
  def test_legacy_too_big_message_is_oversized
    assert(Relay::FcmClient.oversized_response?('400', fcm_error('Android message is too big')))
  end

  # INVALID_ARGUMENT は request 側のバグでも返る。サイズ以外は oversized にしない。
  def test_other_invalid_argument_is_not_oversized
    body = fcm_error('The registration token is not a valid FCM registration token')

    refute(Relay::FcmClient.oversized_response?('400', body))
  end

  def test_non_400_is_not_oversized
    body = fcm_error('Message is too large. The maximum is 4K (4096 bytes).')

    refute(Relay::FcmClient.oversized_response?('500', body))
  end

  def test_non_json_body_is_not_oversized
    refute(Relay::FcmClient.oversized_response?('400', '<html>Bad Request</html>'))
  end
end
