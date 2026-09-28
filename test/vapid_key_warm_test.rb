require_relative 'test_helper'
require_relative 'support/vapid_test_keys'
require 'json'
require 'monitor'
require 'relay/vapid_key_directory'
require 'relay/vapid_key_ledger'

# 冷えたキャッシュの窓を消す (#78)。
#
# ⚠⚠ **なぜ要るのか。**枠は [Relay::VapidKeyLedger::MAX_CONCURRENT_DISCOVERY] で
# **1 本**に絞ってある（別ホストを名乗る 2 件で puma の 2 スレッドが埋まるため）。
# そのぶん、**キャッシュが冷えている数秒のあいだに同時に来た push は `busy`**
# になる —— 2026-09-28 の本番投入直後に **3 通中 2 通**で実測した。
#
# 🔴 **`busy` は 503 で、Misskey は 5xx を再送しない**（`PushNotificationService.ts`
# の `.catch` は 410 しか見ない・2026-09-28 に 2026.9.1 のソースで確認）。
# **通知が黙って消える。**Mastodon は `retry: 5` なので遅れるだけ。⚠ **弱いほうに
# 合わせて、`busy` を極力出さない。**
#
# ⚠ **この検査の期待値が逆だったら:** `busy` が出っぱなしになり、enforce 下で
# **Misskey 宛の通知が再起動のたびに落ちる。**
class VapidKeyWarmTest < Minitest::Test
  HOSTS = ['mstdn.b-shock.org', 'misskey.delmulin.com'].freeze
  KEY_A, KEY_B = VapidTestKeys.generate(2)
  MASTODON_URL = 'https://mstdn.b-shock.org/api/v2/instance'.freeze
  MISSKEY_URL = 'https://misskey.delmulin.com/api/meta'.freeze
  BUSY = Relay::VapidKeyLedger::BUSY

  # 呼ばれた URL を覚える偽の HTTP。⚠ **同時に何本走ったか**も数える。
  class FakeFetch
    attr_reader :calls, :max_concurrent

    def initialize(responses, delay: 0)
      @responses = responses
      @delay = delay
      @calls = []
      @concurrent = 0
      @max_concurrent = 0
      @mon = Monitor.new
    end

    def to_proc
      return lambda do |uri, _payload|
        enter
        begin
          sleep(@delay) if @delay.positive?
          next @responses[uri.to_s]
        ensure
          leave
        end
      end
    end

    private

    def enter
      @mon.synchronize do
        @calls << nil
        @concurrent += 1
        @max_concurrent = [@max_concurrent, @concurrent].max
      end
    end

    def leave
      @mon.synchronize {@concurrent -= 1}
    end
  end

  def bodies
    return {
      MASTODON_URL => JSON.generate({configuration: {vapid: {public_key: KEY_A}}}),
      MISSKEY_URL => JSON.generate({swPublickey: KEY_B}),
    }
  end

  def directory(responses, **)
    fetch = FakeFetch.new(responses, **)
    return [Relay::VapidKeyDirectory.new(hosts: HOSTS, fetch: fetch.to_proc), fetch]
  end

  # --- 起動時の先読み -----------------------------------------------------
  # ⚠⚠ **これが眼目。**先読みが効いていれば、そのあとの照合は**外向き HTTP を
  # 1 本も出さない**＝枠を取り合わない＝ `busy` にならない。
  #
  # ⚠ **「鍵が返る」だけを見ない。**先読みが空振りでも、その場で引けば鍵は返る
  # ので検査が素通りする（2026-09-28 に実際にそう書いて踏んだ）。**増えない
  # ことを見る。**
  def test_warm_fills_the_cache_so_later_lookups_make_no_requests
    dir, fetch = directory(bodies)
    dir.warm!.join
    warmed = fetch.calls.size

    assert_equal(3, warmed, '先読みで 3 本（Mastodon の形 2 回 + Misskey の形 1 回）')
    assert_equal(KEY_A, dir.public_key_for('mstdn.b-shock.org'))
    assert_equal(KEY_B, dir.public_key_for('misskey.delmulin.com'))
    assert_equal(warmed, fetch.calls.size, '先読み済みなので外向き HTTP は増えない')
  end

  # ⚠ **起動をブロックしない**（別スレッドで走る）。
  def test_warm_returns_a_thread_without_blocking
    dir, = directory(bodies, delay: 0.05)
    thread = dir.warm!

    assert_instance_of(Thread, thread)
    thread.join
  end

  # ⚠⚠ **直列に引く。**並列にすると push の受け口と枠を奪い合う。
  def test_warm_never_runs_two_lookups_at_once
    dir, fetch = directory(bodies, delay: 0.02)
    dir.warm!.join

    assert_equal(1, fetch.max_concurrent, '先読みは 1 本ずつ')
  end

  # ⚠ 引けなくても起動を壊さない（negative cache に入るだけ）。
  def test_warm_survives_a_server_that_cannot_be_reached
    dir, = directory({})

    dir.warm!.join

    assert_nil(dir.public_key_for('mstdn.b-shock.org'))
  end

  # --- ⚠⚠ 枠が取れないときに手元の鍵を使う -------------------------------

  # ⚠⚠ **期限が切れていても、手元に鍵があれば `busy` にしない。**
  #
  # 手順: A を引く → 期限切れにする → **別スレッドが B を引いて枠を占有** →
  # そのあいだに A を訊く。従来はここが `busy` だった。
  def test_an_expired_key_is_served_instead_of_busy_when_the_slot_is_taken
    now = 1000.0
    entered = Queue.new
    release = Queue.new
    fetch = lambda do |uri, _payload|
      next bodies[uri.to_s] unless uri.to_s == MISSKEY_URL

      entered << true
      release.pop
      bodies[MISSKEY_URL]
    end
    dir = Relay::VapidKeyDirectory.new(
      hosts: HOSTS, fetch: fetch, ttl: 60, clock: -> {now},
    )

    assert_equal(KEY_A, dir.public_key_for('mstdn.b-shock.org'))

    now += 61 # ⚠ 期限切れ。引き直しの間隔（60 秒）も明けている
    held = Thread.new {dir.public_key_for('misskey.delmulin.com')}
    entered.pop # B を引いている最中＝枠は埋まっている

    assert_equal(
      KEY_A, dir.public_key_for('mstdn.b-shock.org'),
      '期限切れでも手元の鍵を返す（busy にしない）'
    )

    release << true
    held.join
  end

  # ⚠⚠ **一度も引けていないホストは `busy` のまま。**手元に鍵が無いのに通すと
  # fail-open になり、同時リクエストで確定的にゲートを抜けられる。
  def test_a_host_never_fetched_still_goes_busy_under_contention
    entered = Queue.new
    release = Queue.new
    slow = lambda do |uri, _payload|
      next nil unless uri.to_s == MASTODON_URL

      entered << true
      release.pop
      bodies[MASTODON_URL]
    end
    dir = Relay::VapidKeyDirectory.new(hosts: HOSTS, fetch: slow)

    first = Thread.new {dir.public_key_for('mstdn.b-shock.org')}
    entered.pop

    assert_equal(BUSY, dir.public_key_for('misskey.delmulin.com'), '手元に鍵が無いので busy')

    release << true
    first.join
  end

  # --- ⚠⚠ 先読みが効いたかを外から見る（#78） ----------------------------
  #
  # ⚠ **counter では代わりにならない。**`relay_vapid_verification_total` は
  # push が来るまで 1 件も出ないので、**空振りに気付けない。**

  def test_cached_counts_starts_empty
    dir, = directory(bodies)

    assert_equal([0, 2], dir.cached_counts)
  end

  def test_cached_counts_rises_after_warm
    dir, = directory(bodies)
    dir.warm!.join

    assert_equal([2, 2], dir.cached_counts)
  end

  # ⚠ 引けなかったホストは数に入らない（negative cache を「持っている」にしない）。
  def test_a_host_that_could_not_be_fetched_is_not_counted
    dir, = directory({MASTODON_URL => bodies[MASTODON_URL]})
    dir.warm!.join

    assert_equal([1, 2], dir.cached_counts)
  end
end
