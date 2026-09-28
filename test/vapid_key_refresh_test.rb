require_relative 'test_helper'
require 'json'
require 'relay/vapid_key_directory'

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
  MASTODON_URL = 'https://mstdn.b-shock.org/api/v2/instance'.freeze
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
    body = mastodon_body('BOldKey')
    dir, = directory({MASTODON_URL => -> {body}}, clock: -> {now})

    assert_equal('BOldKey', dir.public_key_for('mstdn.b-shock.org'))

    body = mastodon_body('BNewKey')
    now += 61

    assert_equal('BNewKey', dir.refresh_key_for('mstdn.b-shock.org'))
    # 引き直した値が手元にも残る。
    assert_equal('BNewKey', dir.public_key_for('mstdn.b-shock.org'))
  end

  # ⚠⚠ **DoS の踏み台にしない。**合わない鍵で叩き続けるだけで、プリセット
  # サーバーへ好きなだけ HTTP を出させられてはいけない。
  def test_refresh_is_throttled
    now = 1000.0
    dir, fetch = directory(
      {MASTODON_URL => mastodon_body('BOldKey')}, clock: -> {now}
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
    responses = {MASTODON_URL => mastodon_body('BOldKey')}
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
    responses = {MASTODON_URL => mastodon_body('BOldKey')}
    dir, = directory(responses, clock: -> {now})
    dir.public_key_for('mstdn.b-shock.org')

    responses.clear
    now += 61
    dir.refresh_key_for('mstdn.b-shock.org')

    assert_equal('BOldKey', dir.public_key_for('mstdn.b-shock.org'))
  end

  # ⚠⚠ **失敗した引き直しもスロットルされる（#69・Codex P1 2 巡目）。**
  # 進めないと、相手が落ちているあいだ **push 1 通ごとに 2 本の外向き HTTP を
  # やり直す** —— timeout のぶん puma のスレッドを占有し、障害中のサーバーを
  # 叩き続ける。
  def test_a_failed_refresh_is_throttled_too
    now = 1000.0
    responses = {MASTODON_URL => mastodon_body('BOldKey')}
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
    responses = {MASTODON_URL => mastodon_body('BOldKey')}
    dir, = directory(responses, clock: -> {now})
    dir.public_key_for('mstdn.b-shock.org')

    responses.clear
    now += 61
    dir.refresh_key_for('mstdn.b-shock.org')

    assert_equal('BOldKey', dir.public_key_for('mstdn.b-shock.org'))
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
    responses = {MASTODON_URL => mastodon_body('BOldKey')}
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
    responses = {MASTODON_URL => mastodon_body('BOldKey')}
    dir, = directory(responses, clock: -> {now})
    dir.public_key_for(HOST)

    responses.clear
    now += 61
    dir.refresh_key_for(HOST)

    assert_equal('BOldKey', dir.public_key_for(HOST))
  end

  # ⚠ 成功した引き直しは、間隔の中でもその鍵を返す（こちらは「最新」なので正しい）。
  def test_a_throttled_success_returns_the_fresh_key
    now = 1000.0
    body = mastodon_body('BOldKey')
    dir, = directory({MASTODON_URL => -> {body}}, clock: -> {now})
    dir.public_key_for(HOST)

    body = mastodon_body('BNewKey')
    now += 61

    assert_equal('BNewKey', dir.refresh_key_for(HOST))
    assert_equal('BNewKey', dir.refresh_key_for(HOST), '間隔の中でも最新を返す')
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
        mastodon_body('BNewKey')
      end,
    }
    dir, fetch = directory(responses)

    first = Thread.new {dir.refresh_key_for(HOST)}
    entered.pop # 1 本目が I/O に入るまで待つ

    # ⚠ **この 4 本は I/O に入ってはいけない**（枠が押さえられているので即 nil）。
    4.times {assert_nil(dir.refresh_key_for(HOST), '引いている最中は nil')}

    assert_equal(1, fetch.calls.size, '外向き HTTP は 1 本だけ')

    release << true

    assert_equal('BNewKey', first.value)
  end
end
