require_relative 'test_helper'
require 'logger'
require 'lib/relay/apns_client'

# Apnotic::Connection の代役。push が返すもの（あるいは raise するもの）を
# 呼び出し順のスクリプトで与える。
class FakeApnsConnection
  attr_reader :closed

  def initialize(script)
    @script = script
    @closed = false
  end

  def push(_notification)
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

# 実 APNs へ繋がずに済むよう、接続の生成と Notification の組み立てだけ差し替える。
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

  def build_notification(*, **)
    return :notification
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

  private

  def build_client(scripts)
    return StubbedApnsClient.new(scripts)
  end

  def failure_response(status, body)
    return FakeApnsResponse.new(status: status, body: body)
  end
end
