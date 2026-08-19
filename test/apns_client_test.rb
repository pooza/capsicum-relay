require_relative 'test_helper'
require 'logger'
require 'lib/relay/apns_client'

# Apnotic::Connection の代役。push が返すもの（あるいは raise するもの）を
# 呼び出し順のスクリプトで与える。
class FakeApnsConnection
  attr_reader :closed, :pushed

  def initialize(script)
    @script = script
    @closed = false
    @pushed = []
  end

  def push(notification)
    @pushed << notification
    action = @script.shift
    raise HTTP2::Error::StreamLimitExceeded if action == :stream_limit
    return action
  end

  # ApnsClient が :error callback を登録するので受け口だけ用意する
  def on(_event, &)
  end

  def close
    @closed = true
  end
end

class FakeApnsResponse
  attr_reader :status, :body, :headers

  def initialize(status:, body:, headers: {})
    @status = status
    @body = body
    @headers = headers
  end

  def ok?
    return @status == 200
  end
end

# 実 APNs へ繋がずに済むよう、接続の生成だけ差し替える。Notification の組み立ては
# 本物を使う（#17 の degrade 判定は組み立て済み payload のバイト数で決まるので、
# ここを stub すると検証の意味が無くなる）。Apnotic::Notification は生成に I/O を
# 伴わないため、そのまま組める。
class StubbedApnsClient < Relay::ApnsClient
  attr_reader :connections

  def initialize(scripts, logger: Logger.new(File::NULL))
    @scripts = scripts
    @connections = []
    super({'apns' => {'bundle_id' => 'test.bundle'}}, logger: logger)
  end

  def current_connection
    return @connection
  end

  private

  def build_connection
    connection = FakeApnsConnection.new(@scripts.fetch(@connections.size, []))
    @connections << connection
    return connection
  end
end

# #25 / #26: APNs 送信経路の例外が素通りして 500 にならないこと。
class ApnsClientTest < Minitest::Test
  OK_RESPONSE = FakeApnsResponse.new(status: 200, body: {}, headers: {'apns-id' => 'abc'})

  # --- #25 ------------------------------------------------------------------

  def test_json_failure_body_keeps_reason_and_permanent_judgement
    client = build_client(0 => [failure_response(410, {'reason' => 'Unregistered'})])
    result = client.push(device_token: 't', payload: {})

    refute(result[:success])
    assert_equal('Unregistered', result[:reason])
    assert(result[:permanent])
    assert_nil(result[:body_snippet])
  end

  # apnotic-1.8.0 の `JSON.parse(@body) rescue @body` により body が String に
  # なるケース。以前はここで dig が NoMethodError になり push が 500 で落ちた。
  def test_non_json_failure_body_returns_failure_instead_of_raising
    client = build_client(0 => [failure_response(503, '<html>503 Service Unavailable</html>')])
    result = client.push(device_token: 't', payload: {})

    refute(result[:success])
    assert_equal(503, result[:status])
    assert_nil(result[:reason])
    refute(result[:permanent])
    refute(result[:oversized])
  end

  def test_non_json_failure_body_is_truncated_into_snippet
    client = build_client(0 => [failure_response(503, "<html>#{'x' * 500}</html>")])
    result = client.push(device_token: 't', payload: {})

    assert_equal(Relay::ApnsClient::BODY_SNIPPET_LIMIT, result[:body_snippet].length)
    assert(result[:body_snippet].start_with?('<html>'))
  end

  def test_blank_failure_body_leaves_snippet_nil
    client = build_client(0 => [failure_response(500, '   ')])
    result = client.push(device_token: 't', payload: {})

    assert_nil(result[:body_snippet])
    assert_nil(result[:reason])
  end

  # --- #26 ------------------------------------------------------------------

  def test_stream_limit_reconnects_and_retries_once
    client = build_client(0 => [:stream_limit], 1 => [OK_RESPONSE])
    result = client.push(device_token: 't', payload: {})

    assert(result[:success])
    assert_equal('abc', result[:id])
    assert_equal(2, client.connections.size)
  end

  def test_stream_limit_closes_the_stale_connection_and_swaps_in_the_new_one
    client = build_client(0 => [:stream_limit], 1 => [OK_RESPONSE])
    client.push(device_token: 't', payload: {})

    assert(client.connections[0].closed)
    refute(client.connections[1].closed)
    assert_same(client.connections[1], client.current_connection)
  end

  def test_stream_limit_twice_falls_back_to_failure_not_an_exception
    client = build_client(0 => [:stream_limit], 1 => [:stream_limit])
    result = client.push(device_token: 't', payload: {})

    refute(result[:success])
    assert_equal('StreamLimitExceeded', result[:reason])
    refute(result[:permanent])
    refute(result[:oversized])
  end

  # 同時に複数スレッドが上限を踏んでも、張り直しは 1 回で済むこと。
  def test_concurrent_stream_limits_rebuild_the_connection_only_once
    client = build_client(0 => [:stream_limit] * 3, 1 => [OK_RESPONSE] * 3)
    threads = Array.new(3) {Thread.new {client.push(device_token: 't', payload: {})}}
    results = threads.map(&:value)

    assert_equal(2, client.connections.size)
    assert(results.all? {|result| result[:success]})
  end

  # --- #17: oversized の degrade ---------------------------------------------

  # 上限内の通常 payload は素通し。degrade の副作用で暗号化 body を落とさない。
  def test_normal_payload_is_sent_untouched
    client = build_client(0 => [OK_RESPONSE])
    result = client.push(device_token: 't', payload: push_payload(body: 'x' * 100))

    assert(result[:success])
    refute(result[:degraded])
    sent = sent_payload(client)

    assert_equal('x' * 100, sent['body'])
    assert_equal('aes128gcm', sent['encoding'])
  end

  # 以前はここで 413 を受けて 1 通まるごと drop していた（端末に何も出ない）。
  def test_oversized_payload_is_degraded_and_delivered
    original = push_payload(body: 'x' * 5000)
    client = build_client(0 => [OK_RESPONSE])
    result = client.push(device_token: 't', payload: original)

    assert(result[:success])
    assert(result[:degraded])
    refute(result[:oversized])
  end

  # degrade は暗号化 payload 由来のキーだけを落とし、宛先の判別に要る
  # account / server と aps.alert は残す（NSE はこの alert を出す）。
  def test_degraded_payload_drops_only_the_encrypted_keys
    client = build_client(0 => [OK_RESPONSE])
    client.push(device_token: 't', payload: push_payload(body: 'x' * 5000))
    sent = sent_payload(client)

    assert_nil(sent['body'])
    assert_nil(sent['encoding'])
    assert_nil(sent['crypto_key'])
    assert_nil(sent['encryption'])
    assert_equal('user@example.com', sent['account'])
    assert_equal('https://example.com', sent['server'])
    assert_equal('user@example.com に通知があります', sent.dig('aps', 'alert', 'body'))
  end

  # 送った payload が上限を割っていること（degrade の目的そのもの）。
  def test_degraded_notification_is_within_the_limit
    client = build_client(0 => [OK_RESPONSE])
    client.push(device_token: 't', payload: push_payload(body: 'x' * 5000))

    assert_operator(
      client.connections[0].pushed.first.body.bytesize,
      :<=,
      Relay::ApnsPayload::PAYLOAD_LIMIT,
    )
  end

  # 観測用に「degrade 前のサイズ」を返す。Sentry の context に載る。
  def test_degraded_result_reports_the_original_size
    client = build_client(0 => [OK_RESPONSE])
    result = client.push(device_token: 't', payload: push_payload(body: 'x' * 5000))

    assert_operator(result[:original_size], :>, Relay::ApnsPayload::PAYLOAD_LIMIT)
  end

  # degrade しても割れない場合は送らずに 413 経路へ倒す（WNS の pre-check と同型）。
  def test_still_oversized_after_degrade_falls_back_to_the_oversized_path
    huge_account = 'a' * 5000
    client = build_client(0 => [OK_RESPONSE])
    result = client.push(
      device_token: 't', payload: push_payload(body: 'x' * 5000, account: huge_account),
    )

    refute(result[:success])
    assert(result[:oversized])
    refute(result[:permanent])
    assert_equal(413, result[:status])
    assert_empty(client.connections[0].pushed, 'must not POST when it cannot fit')
  end

  # お知らせ通知 (capsicum#477) は元から body / encoding を持たない。degrade
  # 判定に巻き込まれず、alert もそのまま維持されること。
  def test_announcement_style_payload_without_body_is_untouched
    client = build_client(0 => [OK_RESPONSE])
    payload = {'notification_type' => 'announcement', 'account' => 'user@example.com'}
    result = client.push(device_token: 't', payload: payload, alert: {title: 'お知らせ', body: '本文'})

    assert(result[:success])
    refute(result[:degraded])
    assert_equal('本文', sent_payload(client).dig('aps', 'alert', 'body'))
  end

  # StreamLimit の再送でも degrade の判定結果を引き継ぐこと。
  def test_degrade_survives_the_stream_limit_retry
    client = build_client(0 => [:stream_limit], 1 => [OK_RESPONSE])
    result = client.push(device_token: 't', payload: push_payload(body: 'x' * 5000))

    assert(result[:success])
    assert(result[:degraded])
    assert_nil(sent_payload(client, connection: 1)['body'])
  end

  private

  def build_client(scripts)
    return StubbedApnsClient.new(scripts)
  end

  def failure_response(status, body)
    return FakeApnsResponse.new(status: status, body: body)
  end

  # build_push_payload (push_helpers) が組む形。
  def push_payload(body:, account: 'user@example.com')
    return {
      'body' => body,
      'encoding' => 'aes128gcm',
      'server' => 'https://example.com',
      'account' => account,
    }
  end

  def sent_payload(client, connection: 0)
    return JSON.parse(client.connections[connection].pushed.last.body)
  end
end
