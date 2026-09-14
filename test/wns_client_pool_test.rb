require_relative 'test_helper'
require 'logger'
require 'lib/relay/http_connection_pool'
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

  # 実物の [Relay::HttpConnectionPool] へ差し込む接続。プールが触る
  # `started?` / `finish` と、クライアントが触る `request` を持つ。
  class PoolableHttp
    attr_reader :host, :port, :requests, :finish_count

    def initialize(host, port, script)
      @host = host
      @port = port
      @script = script
      @requests = []
      @started = true
      @finish_count = 0
    end

    def started?
      return @started
    end

    def finish
      @finish_count += 1
      @started = false
      return @finish_count
    end

    def request(req)
      @requests << req
      outcome = @script.shift
      raise outcome if outcome.is_a?(Exception)

      return outcome
    end
  end

  # checkout / checkin / discard を記録するプール。1 本ずつ台本を渡す。
  class FakePool
    attr_reader :checked_in, :discarded, :connections, :fresh_checkouts

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

    # ⚠ #64: 張り直しはこちらを通る。⚠⚠ **この double は「新品を返す」ことを
    # 前提に書けてしまう**ので、実物のプールを使う検査を別に置いてある
    # （[test_retry_does_not_borrow_another_idle_connection]）。
    def checkout_fresh(_host, _port)
      @fresh_checkouts = (@fresh_checkouts || 0) + 1
      http = FakeHttp.new(@scripts.shift || [])
      @connections << http
      return http
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

  # ⚠ #64: 張り直しは `checkout` ではなく `checkout_fresh` を通る。
  def test_retry_borrows_through_checkout_fresh
    pool = FakePool.new([[EOFError.new('stale')], [ok_response]], reused: true)
    push(pool)

    assert_equal(1, pool.fresh_checkouts, '張り直しがプールの通常経路を使っている')
  end

  # ⚠⚠ **実物のプールで確かめる (#64)。**上の double は「`checkout_fresh` は
  # 新品を返す」と書いた自分自身に同意するだけなので、**本番で起きた形**
  # （アイドルが 2 本とも閉じられている）は再現できない。
  #
  # 本番のイベントは `ECONNRESET` が 2 本連なり、**2 本とも
  # `begin_transport` → `eof?`** だった。この分岐は「過去にリクエストを通した
  # 接続」でしか通らないので、**張り直したはずの 2 本目もプールのアイドル**
  # だったと分かる。
  def test_retry_does_not_borrow_another_idle_connection
    built = []
    pool = Relay::HttpConnectionPool.new(
      logger: Logger.new(File::NULL),
      factory: lambda {|host, port|
        # 先に積む 2 本は stale（相手に切られている）、張り直しの 1 本は健全。
        http = PoolableHttp.new(host, port, built.size < 2 ? [Errno::ECONNRESET.new('reset')] : [ok_response])
        built << http
        next http
      },
    )
    # アイドルを 2 本（= MAX_IDLE_PER_HOST）積む。⚠ **先に 2 本とも借りてから
    # 返す。**1 本ずつ借りて返すと、2 本目の checkout が 1 本目を再利用して
    # しまい、アイドルは 1 本しか積まれない（本番の形にならない）。
    borrowed = Array.new(2) {pool.checkout('db5p.notify.windows.com', 443).first}
    borrowed.each {|http| pool.checkin('db5p.notify.windows.com', 443, http)}

    assert_equal(2, pool.idle_count)

    result = push(pool)

    assert(result[:success], '張り直しが新品を借りていれば通る')
    assert_equal('reopened', result[:conn])
    assert_equal(3, built.size, '2 本の stale を使い切らずに 3 本目を開く')
    assert_predicate(built[1].requests, :any?, '1 本目の stale は実際に踏んでいる（空振りの検査にしない）')
    assert_empty(built[0].requests, '⚠ 残っていたもう 1 本の stale を借りていない')
    assert_equal(1, built[0].finish_count, '道連れのアイドルは閉じる')
    assert_equal(1, pool.idle_count, '成功した新品だけがプールへ戻る')
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
