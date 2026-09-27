require_relative 'test_helper'
require 'lib/relay/fcm_client'
require 'lib/relay/apns_payload'
require 'lib/relay/push_outcome'

# #71: FCM の 4KB 超過を oversized と判定し、送る前に汎用文面へ degrade する。
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
  # --- build_data（送る前の degrade）----------------------------------------

  def push_payload(body_bytes, account: 'pooza@example.test')
    return {
      'body' => 'A' * body_bytes,
      'encoding' => 'aesgcm',
      'crypto_key' => 'dh=xxx',
      'encryption' => 'salt=yyy',
      'server' => 'example.test',
      'account' => account,
    }
  end

  def test_small_payload_is_sent_as_is
    data, degraded_from = Relay::FcmClient.build_data(push_payload(100))

    assert_nil(degraded_from)
    assert_equal('A' * 100, data['body'])
  end

  # 2026-09 の本番で落ちていたのは 5,000〜6,000B 級の Misskey 通知。
  def test_large_payload_drops_encrypted_keys
    payload = push_payload(6000)
    data, degraded_from = Relay::FcmClient.build_data(payload)

    assert_equal(payload.to_json.bytesize, degraded_from)
    assert_equal({'server' => 'example.test', 'account' => 'pooza@example.test'}, data)
    assert_operator(data.to_json.bytesize, :<=, Relay::FcmClient::PAYLOAD_LIMIT)
  end

  # 上限ちょうどは送る（1 バイト超えから degrade）。
  def test_payload_at_the_limit_is_not_degraded
    base = push_payload(0)
    filler = Relay::FcmClient::PAYLOAD_LIMIT - base.to_json.bytesize
    payload = push_payload(filler)

    assert_equal(Relay::FcmClient::PAYLOAD_LIMIT, payload.to_json.bytesize)
    assert_nil(Relay::FcmClient.build_data(payload)[1])
    assert(Relay::FcmClient.build_data(push_payload(filler + 1))[1])
  end

  # degrade しても割れないとき（account だけで 4KB を超える等）は送らない。
  def test_payload_that_stays_too_large_is_not_sent
    data, degraded_from = Relay::FcmClient.build_data(push_payload(10, account: 'x' * 5000))

    assert_nil(data)
    assert(degraded_from)
  end

  # 値はすべて文字列で送る（FCM data の制約）。degrade 後も同じ。
  def test_values_are_stringified
    data, = Relay::FcmClient.build_data(push_payload(10).merge('server' => :sym))

    assert_equal('sym', data['server'])
  end

  # 落とすキーは APNs / WNS と同じ集合。片方だけ足すと、そのプラットフォームだけ
  # 復号を試みて失敗する（本文の無い暗号化同伴キーが残る）。
  def test_encrypted_keys_match_apns
    assert_equal(Relay::ApnsPayload::ENCRYPTED_KEYS, Relay::FcmClient::ENCRYPTED_KEYS)
  end

  # --- 結末の分類 ------------------------------------------------------------

  def test_precheck_failure_is_classified_as_oversized
    result = Relay::FcmClient.allocate.send(:oversized_precheck_result)

    assert_equal('oversized', Relay::PushOutcome.classify(result))
  end

  def test_degraded_delivery_is_classified_as_degraded
    response = Struct.new(:body).new('{"name":"projects/x/messages/1"}')
    result = Relay::FcmClient.allocate.send(:delivered, response, 6000)

    assert_equal('degraded', Relay::PushOutcome.classify(result))
    assert_equal(6000, result[:original_size])
  end
end
