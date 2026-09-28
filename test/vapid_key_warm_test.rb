require_relative 'test_helper'
require_relative 'support/vapid_test_keys'
require 'json'
require 'monitor'
require 'timeout'
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
  HOST_A = 'mstdn.b-shock.org'.freeze
  HOST_B = 'misskey.delmulin.com'.freeze
  HOSTS = [HOST_A, HOST_B].freeze
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
    dir.warm!(interval: nil).join
    warmed = fetch.calls.size

    assert_equal(3, warmed, '先読みで 3 本（Mastodon の形 2 回 + Misskey の形 1 回）')
    assert_equal(KEY_A, dir.public_key_for('mstdn.b-shock.org'))
    assert_equal(KEY_B, dir.public_key_for('misskey.delmulin.com'))
    assert_equal(warmed, fetch.calls.size, '先読み済みなので外向き HTTP は増えない')
  end

  # ⚠⚠ **温め終えてから返る**（PR #79 の Codex P1）。背景に投げっぱなしにすると、
  # **温めている最中に来た push が `busy` になる**（warm が唯一の枠を握るうえ、
  # まだ温まっていないホストには手元の鍵も無い）。
  def test_warm_finishes_before_returning
    dir, = directory(bodies)
    dir.warm!(interval: nil)

    assert_equal({fresh: 2, total: 2}, dir.cached_counts, '返った時点で温まっている')
  end

  # ⚠⚠ **ただし無制限には待たない。**ホストが落ちていると 1 台で最大 12 秒かかり、
  # ⚠ **待っている間 puma は listen していない ＝ nginx が 502**。🔴 Misskey は
  # 502 でも通知を捨てるので、待ち過ぎは `busy` より悪い。
  def test_warm_stops_waiting_after_the_budget_and_continues_in_the_background
    dir, = directory(bodies, delay: 0.2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    thread = dir.warm!(budget: 0.05, interval: nil)
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator(waited, :<, 0.2, '上限で待つのをやめる')
    refute_equal({fresh: 2, total: 2}, dir.cached_counts, 'まだ温め終えていない')

    thread.join

    assert_equal({fresh: 2, total: 2}, dir.cached_counts, '背景で続きが進む')
  end

  # ⚠⚠ **直列に引く。**並列にすると push の受け口と枠を奪い合う。
  def test_warm_never_runs_two_lookups_at_once
    dir, fetch = directory(bodies, delay: 0.02)
    dir.warm!(interval: nil).join

    assert_equal(1, fetch.max_concurrent, '先読みは 1 本ずつ')
  end

  # ⚠ 引けなくても起動を壊さない（negative cache に入るだけ）。
  def test_warm_survives_a_server_that_cannot_be_reached
    dir, = directory({})

    dir.warm!(interval: nil).join

    assert_nil(dir.public_key_for('mstdn.b-shock.org'))
  end

  # --- 🔴 期限切れの鍵で認証させない（PR #79 の締めの Codex P1） -----------

  # 🔴 **鍵が漏れてローテーションされた場合を考える。**期限切れの鍵を「枠が
  # 取れなかったから」という理由で照合に使うと、⚠⚠ **攻撃者は別のホストで枠を
  # 占有し続けるだけで、捨てたはずの鍵を無期限に通せる。**
  #
  # ⚠ `classify_preset_claim` は**一致した時点で `verified`** にして
  # `refresh_key_for` を呼ばないので、「合わなければ引き直す」では守れない。
  #
  # ⚠ **`busy`（503）を返すほうを選ぶ。**🔴 Misskey は 5xx を再送しないので
  # 通知は落ちるが、**失効した資格情報が通り続けるほうが重い。**冷えた窓は
  # [warm!] で消してある。
  def test_an_expired_key_is_not_used_for_matching_under_contention
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

    assert_equal(KEY_A, dir.public_key_for(HOST_A))

    now += 61 # ⚠ 期限切れ。引き直しの間隔（60 秒）も明けている
    other = Thread.new {dir.public_key_for(HOST_B)}
    entered.pop # B を引いている最中＝枠は埋まっている

    assert_equal(
      BUSY, dir.public_key_for(HOST_A),
      '期限切れの鍵は照合に使わない（失効した鍵が通り続けるのを防ぐ）'
    )

    release << true
    other.join
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

    assert_equal({fresh: 0, total: 2}, dir.cached_counts)
  end

  def test_cached_counts_rises_after_warm
    dir, = directory(bodies)
    dir.warm!(interval: nil).join

    assert_equal({fresh: 2, total: 2}, dir.cached_counts)
  end

  # ⚠ 引けなかったホストは数に入らない（negative cache を「持っている」にしない）。
  def test_a_host_that_could_not_be_fetched_is_not_counted
    dir, = directory({MASTODON_URL => bodies[MASTODON_URL]})
    dir.warm!(interval: nil).join

    assert_equal({fresh: 1, total: 2}, dir.cached_counts)
  end

  # ⚠⚠ **TTL が切れたら `fresh` が減る（PR #79 の Codex P2）。**
  #
  # ⚠ 期限切れを混ぜて数えると、**手元の鍵は残るので数字が永久に満室のまま**に
  # なり、「冷えている」が監視から読めない。
  #
  # ⚠ `fresh` が `total` を下回った ＝ ⚠⚠ **そのホスト宛の push は `busy` に
  # なり得る**（期限切れの鍵は照合に使わないため）。
  def test_an_expired_key_lowers_fresh
    now = 1000.0
    fetch = FakeFetch.new(bodies)
    dir = Relay::VapidKeyDirectory.new(
      hosts: HOSTS, fetch: fetch.to_proc, ttl: 60, clock: -> {now},
    )
    dir.warm!(interval: nil)

    assert_equal({fresh: 2, total: 2}, dir.cached_counts)

    now += 61

    assert_equal({fresh: 0, total: 2}, dir.cached_counts, '期限が切れたら数字が動く')
  end

  # --- ⚠⚠ TTL の前に引き直し続ける（PR #79 の Codex P1） -----------------

  # `refresh_key_for` の呼ばれ方だけ見る代役。⚠ 実際の引き直しは
  # [Relay::VapidKeyLedger::MIN_REFRESH_INTERVAL]（60 秒）で絞られているので、
  # **本物を使うと短い間隔では 2 巡目が観測できない。**
  class CountingDirectory < Relay::VapidKeyDirectory
    attr_reader :refreshed

    def initialize(**)
      super
      @refreshed = Queue.new
    end

    def refresh_key_for(host)
      @refreshed << host
      return nil
    end
  end

  # ⚠⚠ **1 回だけ温めても足りない。**起動時に全ホストをほぼ同時に覚えるので、
  # **TTL 後に一斉に期限切れになり、冷えたバーストがそのまま戻る。**
  # ⚠ **この検査が無いと、長く動いているプロセスだけが踏む**（起動直後しか見て
  # いない検査では一生出ない）。
  def test_warm_keeps_refreshing_so_the_keys_never_expire_together
    dir = CountingDirectory.new(hosts: HOSTS, fetch: FakeFetch.new(bodies).to_proc)
    thread = dir.warm!(interval: 0.01)

    begin
      Timeout.timeout(3) do
        assert_equal(HOSTS.to_a.sort, [dir.refreshed.pop, dir.refreshed.pop].sort)
      end
    ensure
      thread.kill
    end
  end

  # ⚠ 間隔を切れば 1 巡で終わる（テストと、繰り返したくない場面のため）。
  def test_warm_without_an_interval_finishes
    dir = CountingDirectory.new(hosts: HOSTS, fetch: FakeFetch.new(bodies).to_proc)
    thread = dir.warm!(interval: nil)
    thread.join

    refute_predicate(thread, :alive?)
    assert_empty(dir.refreshed)
  end

  # --- ⚠⚠ 1 台の妙な応答で残りを巻き添えにしない（Codex P2） -------------

  # 🔴 **形は正しいが中身が違う JSON。**`{"configuration":"unexpected"}` は
  # `String#dig` が無いので、素直に書くと **TypeError** が飛ぶ。
  BROKEN_SHAPE = '{"configuration":"unexpected"}'.freeze

  # ⚠⚠ **先読みが止まるだけの話ではない。**[public_key_for] は route から
  # 呼ばれていて**例外を捕まえていない**ので、これが飛ぶと **`/push` が 500**。
  def test_a_json_of_the_wrong_shape_does_not_raise
    dir, = directory({MASTODON_URL => BROKEN_SHAPE, MISSKEY_URL => BROKEN_SHAPE})

    assert_nil(dir.public_key_for(HOST_A))
  end

  # ⚠ 1 台が妙でも、残りのホストは温まる。
  def test_one_odd_host_does_not_cancel_the_rest
    dir, = directory(
      {
        MASTODON_URL => BROKEN_SHAPE,
        "https://#{HOST_B}/api/v2/instance" => BROKEN_SHAPE,
        MISSKEY_URL => JSON.generate({swPublickey: KEY_B}),
      },
    )
    dir.warm!(interval: nil).join

    assert_equal({fresh: 1, total: 2}, dir.cached_counts, '妙な 1 台の巻き添えにしない')
  end
end
