require_relative 'test_helper'
require 'logger'
require 'lib/relay/http_connection_pool'

# #54: ホスト別 keep-alive プール。
#
# ⚠ **factory を差し替えてネットワークに触らずに検査する。**実際の `Net::HTTP` は
# start で外へ出るので、ここでは「開始済みの接続」のふりをする最小の double を使う。
class HttpConnectionPoolTest < Minitest::Test
  # Net::HTTP のうちプールが触るのは started? / finish だけ。
  class FakeHttp
    attr_reader :host, :port, :finish_count

    def initialize(host, port)
      @host = host
      @port = port
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

    # 相手に切られた状態（started? は true のまま）を作るための細工ではなく、
    # 「自分で閉じた」状態を作るためのもの。
    def force_closed!
      @started = false
    end
  end

  def setup
    @built = []
  end

  def test_first_checkout_opens_a_connection
    pool = build_pool

    http, reused = pool.checkout('db5p.notify.windows.com', 443)

    refute(reused, '1 本目は再利用ではない')
    assert_equal(1, @built.size)
    assert_equal('db5p.notify.windows.com', http.host)
  end

  # ⚠⚠ **これが #54 の本体。**checkin したものが次の checkout で戻ってくる。
  def test_checked_in_connection_is_reused
    pool = build_pool
    first, = pool.checkout('db5p.notify.windows.com', 443)
    pool.checkin('db5p.notify.windows.com', 443, first)

    second, reused = pool.checkout('db5p.notify.windows.com', 443)

    assert(reused)
    assert_same(first, second)
    assert_equal(1, @built.size, '2 回目は新しい接続を作らない')
  end

  # ⚠ 貸出中はプールに残らない（`Net::HTTP` は同時リクエストが安全でない）。
  def test_checked_out_connection_is_not_handed_out_twice
    pool = build_pool
    first, = pool.checkout('db5p.notify.windows.com', 443)
    second, reused = pool.checkout('db5p.notify.windows.com', 443)

    refute(reused)
    refute_same(first, second)
    assert_equal(2, @built.size)
  end

  # ⚠ region が db5p / sg2p に分かれるので、ホストを跨いで使い回さない。
  def test_hosts_do_not_share_connections
    pool = build_pool
    first, = pool.checkout('db5p.notify.windows.com', 443)
    pool.checkin('db5p.notify.windows.com', 443, first)

    other, reused = pool.checkout('sg2p.notify.windows.com', 443)

    refute(reused)
    refute_same(first, other)
  end

  # ⚠⚠ **アイドルの見切りは checkout 時に効く**（reaper を置いていない）。
  def test_idle_connection_is_discarded_after_timeout
    pool = build_pool(idle_timeout: 0)
    first, = pool.checkout('db5p.notify.windows.com', 443)
    pool.checkin('db5p.notify.windows.com', 443, first)

    second, reused = pool.checkout('db5p.notify.windows.com', 443)

    refute(reused, 'アイドル上限を超えたら再利用しない')
    refute_same(first, second)
    assert_equal(1, first.finish_count, '捨てた接続は閉じる')
  end

  def test_closed_connection_is_not_reused
    pool = build_pool
    first, = pool.checkout('db5p.notify.windows.com', 443)
    pool.checkin('db5p.notify.windows.com', 443, first)
    first.force_closed!

    _second, reused = pool.checkout('db5p.notify.windows.com', 443)

    refute(reused)
  end

  def test_closed_connection_is_not_kept_on_checkin
    pool = build_pool
    http, = pool.checkout('db5p.notify.windows.com', 443)
    http.force_closed!

    refute(pool.checkin('db5p.notify.windows.com', 443, http))
    assert_equal(0, pool.idle_count)
  end

  # 上限を超えたぶんは持たずに閉じる（puma の threads 数で足りる）。
  def test_keeps_at_most_max_idle_per_host
    pool = build_pool(max_idle_per_host: 1)
    first, = pool.checkout('db5p.notify.windows.com', 443)
    second, = pool.checkout('db5p.notify.windows.com', 443)

    assert(pool.checkin('db5p.notify.windows.com', 443, first))
    refute(pool.checkin('db5p.notify.windows.com', 443, second))
    assert_equal(1, pool.idle_count)
    assert_equal(1, second.finish_count)
  end

  def test_discard_closes_and_does_not_pool
    pool = build_pool
    http, = pool.checkout('db5p.notify.windows.com', 443)

    pool.discard(http)

    assert_equal(1, http.finish_count)
    assert_equal(0, pool.idle_count)
  end

  def test_close_all_closes_idle_connections
    pool = build_pool
    first, = pool.checkout('db5p.notify.windows.com', 443)
    second, = pool.checkout('sg2p.notify.windows.com', 443)
    pool.checkin('db5p.notify.windows.com', 443, first)
    pool.checkin('sg2p.notify.windows.com', 443, second)

    assert_equal(2, pool.close_all)
    assert_equal(0, pool.idle_count)
    assert_equal(1, first.finish_count)
    assert_equal(1, second.finish_count)
  end

  # ホスト名の大小を揃える（Channel URI の host は大文字でも来うる）。
  def test_host_is_case_insensitive
    pool = build_pool
    first, = pool.checkout('DB5P.notify.windows.com', 443)
    pool.checkin('DB5P.notify.windows.com', 443, first)

    second, reused = pool.checkout('db5p.notify.windows.com', 443)

    assert(reused)
    assert_same(first, second)
  end

  # ⚠⚠ **これが抜けると計測が嘘をつく。**`Net::HTTP#keep_alive_timeout` の既定は
  # 2 秒で、それを超えて空いた接続は Net::HTTP 自身が黙って張り直す。プールは
  # 「再利用した」と言い続けるのに、実際は毎回 TLS を張っている状態になる。
  def test_configure_raises_keep_alive_timeout_above_the_default
    pool = Relay::HttpConnectionPool.new(idle_timeout: 55)
    http = Net::HTTP.new('db5p.notify.windows.com', 443)

    assert_equal(2, http.keep_alive_timeout, '前提: Net::HTTP の既定は 2 秒')
    pool.send(:configure, http)

    assert_equal(55, http.keep_alive_timeout)
    assert_predicate(http, :use_ssl?)
    assert_equal(Relay::HttpConnectionPool::OPEN_TIMEOUT, http.open_timeout)
    assert_equal(Relay::HttpConnectionPool::READ_TIMEOUT, http.read_timeout)
  end

  private

  def build_pool(**)
    return Relay::HttpConnectionPool.new(
      logger: Logger.new(File::NULL),
      factory: lambda {|host, port|
        http = FakeHttp.new(host, port)
        @built << http
        http
      },
      **,
    )
  end
end
