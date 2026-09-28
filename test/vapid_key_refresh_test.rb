require_relative 'test_helper'
require_relative 'support/vapid_test_keys'
require 'json'
require 'relay/vapid_key_directory'
require 'relay/vapid_key_ledger'

# 鍵の引き直し (capsicum#597 / #69・PR #77 の Codex P1)。
#
# ⚠⚠ **これが無いと、プリセットサーバーが VAPID を作り直しただけで、本物の
# push が詐称扱いになる。**ゲートを閉じていれば 410 を返し、**上流の購読が
# 永久に消える。**取り返しがつかないので、詐称と決める前に必ず引き直す。
#
# ⚠ **ただし引き直し自体が DoS の踏み台になる。**引き直しは「鍵が合わない push が
# 来た」ときに走るので、**合わない鍵で叩き続けるだけで、プリセットサーバーへ
# 好きなだけ HTTP を出させられる。**成功でも失敗でもスロットルが効くこと。
class VapidKeyRefreshTest < Minitest::Test
  HOSTS = ['mstdn.b-shock.org'].freeze
  # ⚠ **本物の P-256 公開鍵を使う**（[VapidTestKeys] の注意書き）。
  OLD_KEY, NEW_KEY, COLD_KEY, ONLY_KEY, OTHER_KEY = VapidTestKeys.generate(5)
  MASTODON_URL = 'https://mstdn.b-shock.org/api/v2/instance'.freeze
  OTHER_HOST = 'precure.ml'.freeze
  BUSY = Relay::VapidKeyLedger::BUSY
  OTHER_MASTODON_URL = 'https://precure.ml/api/v2/instance'.freeze
  HOST = 'mstdn.b-shock.org'.freeze

  # 呼ばれた URL を覚える偽の HTTP。[responses] は URL => body（Proc も可）。
  class FakeFetch
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def to_proc
      return lambda do |uri, _payload|
        @calls << uri.to_s
        next @responses[uri.to_s]&.call if @responses[uri.to_s].is_a?(Proc)

        @responses[uri.to_s]
      end
    end
  end

  def mastodon_body(key)
    return JSON.generate({configuration: {vapid: {public_key: key}}})
  end

  def directory(responses, **)
    fetch = FakeFetch.new(responses)
    return [Relay::VapidKeyDirectory.new(hosts: HOSTS, fetch: fetch.to_proc, **), fetch]
  end

  # **鍵の更新を詐称と誤らないための口。**誤ると 410 で上流の購読が永久に消える。
  def test_refresh_bypasses_the_cache_and_picks_up_the_new_key
    now = 1000.0
    body = mastodon_body(OLD_KEY)
    dir, = directory({MASTODON_URL => -> {body}}, clock: -> {now})

    assert_equal(OLD_KEY, dir.public_key_for('mstdn.b-shock.org'))

    body = mastodon_body(NEW_KEY)
    now += 61

    assert_equal(NEW_KEY, dir.refresh_key_for('mstdn.b-shock.org'))
    # 引き直した値が手元にも残る。
    assert_equal(NEW_KEY, dir.public_key_for('mstdn.b-shock.org'))
  end

  # ⚠⚠ **DoS の踏み台にしない。**合わない鍵で叩き続けるだけで、プリセット
  # サーバーへ好きなだけ HTTP を出させられてはいけない。
  def test_refresh_is_throttled
    now = 1000.0
    dir, fetch = directory(
      {MASTODON_URL => mastodon_body(OLD_KEY)}, clock: -> {now}
    )
    dir.public_key_for('mstdn.b-shock.org')
    before = fetch.calls.size

    10.times {dir.refresh_key_for('mstdn.b-shock.org')}

    assert_equal(before, fetch.calls.size, '間隔内は引き直さない')

    now += 61
    dir.refresh_key_for('mstdn.b-shock.org')

    assert_operator(fetch.calls.size, :>, before)
  end

  # ⚠⚠ **引き直せなかったら nil。**古い鍵を返すと、呼び出し側が
  # 「更新ではない＝詐称」と決めてしまう。
  def test_refresh_returns_nil_when_the_fetch_fails
    now = 1000.0
    responses = {MASTODON_URL => mastodon_body(OLD_KEY)}
    dir, = directory(responses, clock: -> {now})
    dir.public_key_for('mstdn.b-shock.org')

    responses.clear
    now += 61

    assert_nil(dir.refresh_key_for('mstdn.b-shock.org'))
  end

  # ⚠ **失敗で手元の記録を壊さない。**negative cache で上書きすると、一時的な
  # 通信障害のあとに「鍵が無い」状態が居座る。
  def test_a_failed_refresh_keeps_the_previous_key
    now = 1000.0
    responses = {MASTODON_URL => mastodon_body(OLD_KEY)}
    dir, = directory(responses, clock: -> {now})
    dir.public_key_for('mstdn.b-shock.org')

    responses.clear
    now += 61
    dir.refresh_key_for('mstdn.b-shock.org')

    assert_equal(OLD_KEY, dir.public_key_for('mstdn.b-shock.org'))
  end

  # ⚠⚠ **失敗した引き直しもスロットルされる（#69・Codex P1 2 巡目）。**
  # 進めないと、相手が落ちているあいだ **push 1 通ごとに 2 本の外向き HTTP を
  # やり直す** —— timeout のぶん puma のスレッドを占有し、障害中のサーバーを
  # 叩き続ける。
  def test_a_failed_refresh_is_throttled_too
    now = 1000.0
    responses = {MASTODON_URL => mastodon_body(OLD_KEY)}
    dir, fetch = directory(responses, clock: -> {now})
    dir.public_key_for('mstdn.b-shock.org')

    responses.clear
    now += 61
    dir.refresh_key_for('mstdn.b-shock.org')
    after_first_failure = fetch.calls.size

    10.times {dir.refresh_key_for('mstdn.b-shock.org')}

    assert_equal(after_first_failure, fetch.calls.size, '失敗しても間隔は効く')
  end

  # ⚠ ただし手元の鍵は残る（失敗で記録を壊さない）。
  def test_a_throttled_failure_still_keeps_the_previous_key
    now = 1000.0
    responses = {MASTODON_URL => mastodon_body(OLD_KEY)}
    dir, = directory(responses, clock: -> {now})
    dir.public_key_for('mstdn.b-shock.org')

    responses.clear
    now += 61
    dir.refresh_key_for('mstdn.b-shock.org')

    assert_equal(OLD_KEY, dir.public_key_for('mstdn.b-shock.org'))
    # ⚠ 間隔が明けたら、手元の鍵を返しつつ引き直しは再開する。
    now += 61

    assert_nil(dir.refresh_key_for('mstdn.b-shock.org'))
  end

  # ⚠ 引き直しも一覧の外へは出て行かない。
  def test_refresh_never_fetches_a_host_outside_the_list
    dir, fetch = directory({})

    assert_nil(dir.refresh_key_for('evil.example.test'))
    assert_empty(fetch.calls)
  end

  # --- ⚠⚠ 3 巡目の Codex P1（2 巡目の修正が作った穴） --------------------

  # ⚠⚠ **間隔のあいだは、失敗を失敗のまま返し続ける。**
  #
  # 手元の古い鍵を返すと、呼び出し側がそれを**引き直した結果**と読んで
  # `mismatch` に倒し、**410 で購読が永久に消える。**2 巡目の修正では
  # **障害中に fail-open になるのは最初の 1 通だけ**で、2 通目以降は
  # 古い鍵を「最新」として返していた。
  def test_a_throttled_failure_keeps_returning_nil
    now = 1000.0
    responses = {MASTODON_URL => mastodon_body(OLD_KEY)}
    dir, = directory(responses, clock: -> {now})
    dir.public_key_for(HOST)

    responses.clear
    now += 61

    assert_nil(dir.refresh_key_for(HOST), '1 通目')
    # ⚠ ここが古い鍵を返していた。
    assert_nil(dir.refresh_key_for(HOST), '2 通目（間隔の中）')
    assert_nil(dir.refresh_key_for(HOST), '3 通目（間隔の中）')
  end

  # ⚠ ただし手元の鍵は生きている（期限まで有効）。引き直しの成否とは別の話。
  def test_a_throttled_failure_does_not_invalidate_the_cached_key
    now = 1000.0
    responses = {MASTODON_URL => mastodon_body(OLD_KEY)}
    dir, = directory(responses, clock: -> {now})
    dir.public_key_for(HOST)

    responses.clear
    now += 61
    dir.refresh_key_for(HOST)

    assert_equal(OLD_KEY, dir.public_key_for(HOST))
  end

  # ⚠⚠ **成功した直後でも、間隔の中では BUSY（#69・Codex P1 7 巡目）。**
  #
  # 🔴 **ここは 3 巡目に「最新を返す」と書いてしまい、不具合を正しい挙動として
  # 固定していた。**「引けた鍵」と「**いま引き直した**鍵」は違う ——
  # **引いた 60 秒の間にサーバーが VAPID を作り直すと、手元の鍵は既に古い。**
  # それを「引き直した結果」として返すと、呼び出し側が**本物の新しい鍵を詐称と
  # 判定し、410 で上流の購読を永久に消す。**
  def test_a_throttled_success_is_busy_not_a_confirmation
    now = 1000.0
    body = mastodon_body(OLD_KEY)
    dir, = directory({MASTODON_URL => -> {body}}, clock: -> {now})
    dir.public_key_for(HOST)

    body = mastodon_body(NEW_KEY)
    now += 61

    assert_equal(NEW_KEY, dir.refresh_key_for(HOST), '間隔が明けたので引き直せる')
    # ⚠ ここで「BNewKey」を返すと、**その 60 秒の間に更新された鍵を詐称と判定する。**
    assert_equal(BUSY, dir.refresh_key_for(HOST), '間隔の中は確認したことにしない')
  end

  # ⚠⚠ **同時要求でも 1 本しか出さない。**枠を I/O の前に押さえていないと、
  # **間隔が明けた直後に来た要求が全部素通りして、puma のスレッドぶん一斉に
  # 外向き HTTP を出す**（＝ 攻撃者が全スレッドを占有できる）。
  def test_a_concurrent_burst_only_triggers_one_discovery
    entered = Queue.new
    release = Queue.new
    responses = {
      MASTODON_URL => lambda do
        entered << true
        release.pop
        mastodon_body(NEW_KEY)
      end,
    }
    dir, fetch = directory(responses)

    first = Thread.new {dir.refresh_key_for(HOST)}
    entered.pop # 1 本目が I/O に入るまで待つ

    # ⚠ **この 4 本は I/O に入ってはいけない**（枠が押さえられているので即 nil）。
    4.times {assert_equal(BUSY, dir.refresh_key_for(HOST), '引いている最中は busy')}

    assert_equal(1, fetch.calls.size, '外向き HTTP は 1 本だけ')

    release << true

    assert_equal(NEW_KEY, first.value)
  end

  # --- ⚠⚠ 4 巡目の Codex P1（単発化が refresh にしか入っていなかった） -----

  # ⚠⚠ **キャッシュミスの経路にも同じ雪崩があった。**起動直後や期限切れの
  # 瞬間に同時要求が来ると、**全部が `discover` に入って puma のスレッドが
  # 揃って timeout を待つ。**枠は `public_key_for` でも I/O の前に押さえる。
  def test_a_cold_cache_burst_only_triggers_one_discovery
    entered = Queue.new
    release = Queue.new
    responses = {
      MASTODON_URL => lambda do
        entered << true
        release.pop
        mastodon_body(COLD_KEY)
      end,
    }
    dir, fetch = directory(responses)

    first = Thread.new {dir.public_key_for(HOST)}
    entered.pop # 1 本目が I/O に入るまで待つ

    # ⚠ **この 4 本は I/O に入ってはいけない。**
    4.times {assert_equal(BUSY, dir.public_key_for(HOST), '引いている最中は busy')}

    assert_equal(1, fetch.calls.size, '外向き HTTP は 1 本だけ')

    release << true

    assert_equal(COLD_KEY, first.value)
  end

  # ⚠ 引き終われば通常どおり手元から返る（枠の押さえが残り続けない）。
  def test_the_reservation_is_released_once_the_fetch_succeeds
    dir, fetch = directory({MASTODON_URL => mastodon_body(COLD_KEY)})

    assert_equal(COLD_KEY, dir.public_key_for(HOST))
    assert_equal(COLD_KEY, dir.public_key_for(HOST))
    assert_equal(1, fetch.calls.size)
  end

  # --- ⚠⚠ 5 巡目の Codex P1（枠がホストごとだけだった） ------------------

  # ⚠⚠ **別のホストを名乗る 2 件で受け口が埋まっていた。**
  #
  # ホストごとの予約は**同じホスト**しか直列化しない。⚠ **puma は 2 スレッド**
  # なのに一覧には **9 ホスト**あるので、2 件同時で relay が push を 1 通も
  # 受け付けられなくなる。⚠ **クライアントは好きなホストを名乗れる**ので、
  # 攻撃者がこれを起こせる。
  def test_discovery_is_capped_across_different_hosts
    entered = Queue.new
    release = Queue.new
    slow = lambda do
      entered << true
      release.pop
      mastodon_body(ONLY_KEY)
    end
    counter = FakeFetch.new({MASTODON_URL => slow, OTHER_MASTODON_URL => slow})
    dir = Relay::VapidKeyDirectory.new(
      hosts: [HOST, OTHER_HOST], fetch: counter.to_proc,
    )
    fetch = counter

    first = Thread.new {dir.public_key_for(HOST)}
    entered.pop # 1 本目が I/O に入るまで待つ

    # ⚠⚠ **別ホストでも I/O に入ってはいけない。**
    assert_equal(BUSY, dir.public_key_for(OTHER_HOST), '別ホストでも全体の枠で止まる')
    assert_equal(1, fetch.calls.size, '外向き HTTP は 1 本だけ')

    release << true

    assert_equal(ONLY_KEY, first.value)
  end

  # ⚠ 全体の枠が取れなかっただけで、そのホストの枠を焼かない。
  # 焼くと、引いてもいないのに 60 秒引き直せなくなる。
  def test_a_lost_global_slot_does_not_burn_the_host_slot
    entered = Queue.new
    release = Queue.new
    slow = lambda do
      entered << true
      release.pop
      mastodon_body(ONLY_KEY)
    end
    counter = FakeFetch.new({MASTODON_URL => slow, OTHER_MASTODON_URL => mastodon_body(OTHER_KEY)})
    dir = Relay::VapidKeyDirectory.new(hosts: [HOST, OTHER_HOST], fetch: counter.to_proc)

    first = Thread.new {dir.public_key_for(HOST)}
    entered.pop

    assert_equal(BUSY, dir.public_key_for(OTHER_HOST), '全体の枠が無いので今は引けない')

    release << true
    first.value

    # ⚠ 枠が空いたら、間隔を待たずに引ける。
    assert_equal(OTHER_KEY, dir.public_key_for(OTHER_HOST))
  end

  # --- ⚠⚠ 待たせる長さ（PR #77 の Codex 締めの P2） ------------------------
  #
  # ⚠⚠ **この期待値が短過ぎると何が起きるか:** 上流は言われたとおりに再送し、
  # **間隔が明けるまで 503 を受け続けて再試行の枠を使い切る** —— 通知が遅れる /
  # 落ちる。⚠ 逆に長過ぎると、枠の取り合いで待たせただけの push を無用に遅らせる。
  # **由来で長さが 1 桁違うので、一律の固定値にしない。**

  CONTENTION = Relay::VapidKeyLedger::CONTENTION_RETRY_AFTER
  INTERVAL = Relay::VapidKeyLedger::MIN_REFRESH_INTERVAL

  # 記録が無い（＝枠の取り合いだけ）なら短い既定値。
  def test_an_unknown_host_waits_only_for_the_contention
    dir, = directory({})

    assert_equal(CONTENTION, dir.retry_after_for(HOST))
  end

  # ⚠⚠ **引いた直後は、間隔が明けるまでの丸ごとを待たせる。**
  def test_just_after_a_fetch_waits_for_the_whole_interval
    now = 1000.0
    dir, = directory({MASTODON_URL => mastodon_body(OLD_KEY)}, clock: -> {now})
    dir.public_key_for(HOST)

    assert_equal(INTERVAL, dir.retry_after_for(HOST))
  end

  # ⚠ 途中なら残りだけ。
  def test_partway_through_the_window_waits_for_the_remainder
    now = 1000.0
    dir, = directory({MASTODON_URL => mastodon_body(OLD_KEY)}, clock: -> {now})
    dir.public_key_for(HOST)
    now += 40

    assert_equal(20, dir.retry_after_for(HOST))
  end

  # ⚠ 明けていても 0 や負にしない（枠の取り合いは残る）。
  def test_after_the_window_falls_back_to_the_contention_wait
    now = 1000.0
    dir, = directory({MASTODON_URL => mastodon_body(OLD_KEY)}, clock: -> {now})
    dir.public_key_for(HOST)
    now += INTERVAL + 10

    assert_equal(CONTENTION, dir.retry_after_for(HOST))
  end

  # ⚠ 一覧の外は待たせる意味が無いので既定値（呼び出し側に分岐を作らない）。
  def test_a_host_outside_the_list_gets_the_default
    dir, = directory({})

    assert_equal(CONTENTION, dir.retry_after_for('evil.example.test'))
  end
end
