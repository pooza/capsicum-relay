require_relative 'test_helper'
require 'logger'
require 'lib/relay/wns_client'

# #54: WNS 送信の接続再利用と、stale keep-alive の 1 回だけの張り直し。
#
# ⚠ **OAuth とネットワークには触らない。**access_token は instance 変数を直接
# 埋めてキャッシュ済みにし、送信はプールを差し替えて double に受けさせる。
class WnsClientPoolTest < Minitest::Test
  CONFIG = {'wns' => {'package_sid' => 'sid', 'client_secret' => 'secret'}}.freeze
  VALID_URI = 'https://db5p.notify.windows.com/w/?token=abc'.freeze

  # Net::HTTP のうち WnsClient が触るのは request だけ。応答か例外を順に返す。
  class FakeHttp
    attr_reader :requests

    def initialize(script)
      @script = script
      @requests = []
    end

    def request(req)
      @requests << req
      outcome = @script.shift
      raise outcome if outcome.is_a?(Exception) || (outcome.is_a?(Class) && outcome <= Exception)

      return outcome
    end
  end

  # checkout / checkin / discard を記録するプール。1 本ずつ台本を渡す。
  class FakePool
    attr_reader :checked_in, :discarded, :connections

    def initialize(scripts, reused:)
      @scripts = scripts
      @reused = reused
      @connections = []
      @checked_in = []
      @discarded = []
    end

    def checkout(_host, _port)
      http = FakeHttp.new(@scripts.shift || [])
      @connections << http
      # 1 本目だけ「再利用した接続」として渡し、2 本目以降は新規扱いにする。
      return [http, @reused && @connections.size == 1]
    end

    def checkin(_host, _port, http)
      @checked_in << http
      return @checked_in.size
    end

    def discard(http)
      @discarded << http
      return @discarded.size
    end

    def close_all
      return 0
    end
  end

  def test_success_on_reused_connection_is_labelled_reused
    pool = FakePool.new([[ok_response]], reused: true)
    result = push(pool)

    assert(result[:success])
    assert_equal('reused', result[:conn])
    assert_equal(1, pool.checked_in.size)
    assert_empty(pool.discarded)
  end

  def test_success_on_fresh_connection_is_labelled_opened
    pool = FakePool.new([[ok_response]], reused: false)
    result = push(pool)

    assert(result[:success])
    assert_equal('opened', result[:conn])
  end

  # ⚠⚠ **ここが再利用の代償。**相手に切られた接続は書き込み時に落ちるので、
  # 張り直して 1 回だけ送り直す。これが無いと、プールを入れたことで**送信失敗が
  # 増える**（今まで無かった経路）。
  def test_stale_reused_connection_is_retried_once_on_a_fresh_connection
    pool = FakePool.new([[EOFError.new('end of file reached')], [ok_response]], reused: true)
    result = push(pool)

    assert(result[:success])
    assert_equal('reopened', result[:conn])
    assert_equal(2, pool.connections.size, '張り直して 2 本目で送る')
    assert_equal([pool.connections.first], pool.discarded, '落ちた接続はプールに戻さない')
    assert_equal([pool.connections.last], pool.checked_in)
  end

  def test_stale_error_is_retried_for_connection_reset_too
    pool = FakePool.new(
      [[Errno::ECONNRESET.new('reset by peer')], [ok_response]], reused: true
    )

    assert_equal('reopened', push(pool)[:conn])
  end

  # ⚠⚠ **新規接続での失敗は再送しない。**相手が受理した直後に応答だけ失った場合、
  # 再送は二重配信になる。stale keep-alive だけが「書く前に落ちた」と言い切れる。
  def test_failure_on_fresh_connection_is_not_retried
    pool = FakePool.new([[EOFError.new('end of file reached')]], reused: false)
    result = push(pool)

    refute(result[:success])
    assert_equal('no_response', result[:reason])
    assert_equal(1, pool.connections.size, '再送していない（POST は 1 回だけ）')
    assert_equal(1, pool.discarded.size)
    assert_empty(pool.checked_in)
  end

  # 張り直した 2 本目も落ちたら、通常の失敗として上へ返す（Sentry 行きの経路）。
  def test_second_failure_after_retry_falls_through_to_failure
    pool = FakePool.new(
      [[EOFError.new('first')], [EOFError.new('second')]], reused: true
    )
    result = push(pool)

    refute(result[:success])
    assert_equal('no_response', result[:reason])
    assert_equal(2, pool.connections.size)
    assert_equal(2, pool.discarded.size)
  end

  # stale 以外の例外（TLS 検証失敗等）は再送対象にしない。
  def test_non_stale_error_is_not_retried
    pool = FakePool.new([[OpenSSL::SSL::SSLError.new('handshake failure')]], reused: true)
    result = push(pool)

    refute(result[:success])
    assert_equal(1, pool.connections.size)
  end

  # 401 は「トークン失効」の経路。⚠ **プール化でこの再送を落としていないこと**を
  # 見る。OAuth の再取得そのものはここの対象外なので、トークン取得は固定値に差し替える
  # （force_refresh で login.live.com へ出るのを止めるため）。
  def test_401_refreshes_token_and_posts_again
    pool = FakePool.new([[response(401)], [ok_response]], reused: false)
    client = build_client(pool)
    client.define_singleton_method(:access_token) {|**| 'token'}
    result = client.push(device_token: VALID_URI, payload: {'a' => 1})

    assert(result[:success])
    assert_equal(2, pool.connections.size, '401 のあと 1 回だけ送り直す')
  end

  # 送信ヘッダは従来どおり（プール化で落としていないこと）。
  def test_request_headers_are_preserved
    pool = FakePool.new([[ok_response]], reused: false)
    push(pool)
    request = pool.connections.first.requests.first

    assert_equal('Bearer token', request['Authorization'])
    assert_equal('application/octet-stream', request['Content-Type'])
    assert_equal('wns/raw', request['X-WNS-Type'])
    assert_equal({'a' => 1}.to_json, request.body)
  end

  private

  def push(pool)
    return build_client(pool).push(device_token: VALID_URI, payload: {'a' => 1})
  end

  # OAuth を叩かせないため、キャッシュ済みトークンを直接埋める。
  def build_client(pool)
    client = Relay::WnsClient.new(CONFIG, logger: Logger.new(File::NULL), pool: pool)
    client.instance_variable_set(:@access_token, 'token')
    client.instance_variable_set(:@token_expires_at, Time.now + 3600)
    return client
  end

  def ok_response
    return response(200, 'X-WNS-NotificationStatus' => 'received')
  end

  def response(code, headers = {})
    res = Net::HTTPResponse.send(:response_class, code.to_s).new('1.1', code.to_s, 'OK')
    headers.each {|key, value| res[key] = value}
    return res
  end
end
