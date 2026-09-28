require_relative 'test_helper'
require 'json'
require 'relay/vapid_key_directory'

# プリセットサーバーの VAPID 公開鍵の取得とキャッシュ (capsicum#597 / #69)。
#
# ⚠⚠ **ここで固定したいのは 4 点。**
#
# 1. ⚠⚠ **一覧に無いホストは取りに行かない**（`server` はクライアントの申告なので、
#    そのまま取りに行くと relay が SSRF の道具になる）
# 2. Mastodon / Misskey の両方の形から読める
# 3. 引けなかったら nil（**倒し方は呼び出し側が決める**）
# 4. ⚠ キャッシュが効く（push 1 通ごとに外向き HTTP を出さない）
class VapidKeyDirectoryTest < Minitest::Test
  HOSTS = ['mstdn.b-shock.org', 'misskey.delmulin.com'].freeze

  # 呼ばれた URL を覚える偽の HTTP。[responses] は URL => body。
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

  MASTODON_URL = 'https://mstdn.b-shock.org/api/v2/instance'.freeze
  MISSKEY_URL = 'https://misskey.delmulin.com/api/meta'.freeze
  MASTODON_MISSKEY_URL = 'https://mstdn.b-shock.org/api/meta'.freeze

  def mastodon_body(key)
    return JSON.generate({configuration: {vapid: {public_key: key}}})
  end

  def misskey_body(key)
    return JSON.generate({swPublickey: key})
  end

  def directory(responses, **)
    fetch = FakeFetch.new(responses)
    return [Relay::VapidKeyDirectory.new(hosts: HOSTS, fetch: fetch.to_proc, **), fetch]
  end

  # --- 取得 ---------------------------------------------------------------

  def test_reads_the_mastodon_shape
    dir, = directory({MASTODON_URL => mastodon_body('BMastodonKey')})

    assert_equal('BMastodonKey', dir.public_key_for('mstdn.b-shock.org'))
  end

  # ⚠ Mastodon の形で取れなければ Misskey の形を試す。
  def test_falls_back_to_the_misskey_shape
    dir, fetch = directory({MISSKEY_URL => misskey_body('BMisskeyKey')})

    assert_equal('BMisskeyKey', dir.public_key_for('misskey.delmulin.com'))
    assert_equal(['https://misskey.delmulin.com/api/v2/instance', MISSKEY_URL], fetch.calls)
  end

  # ⚠ Mastodon で取れたら Misskey は叩かない。
  def test_does_not_probe_misskey_when_mastodon_answers
    dir, fetch = directory({MASTODON_URL => mastodon_body('BMastodonKey')})
    dir.public_key_for('mstdn.b-shock.org')

    refute_includes(fetch.calls, MASTODON_MISSKEY_URL)
  end

  # ⚠ 比較の前に形を揃える（パディングと `+/`）。
  def test_normalizes_the_stored_key
    dir, = directory({MASTODON_URL => mastodon_body("BKey+with/chars==\n")})

    assert_equal('BKey-with_chars', dir.public_key_for('mstdn.b-shock.org'))
  end

  # --- ⚠⚠ 一覧の外は取りに行かない（SSRF を作らない） ----------------------

  def test_never_fetches_a_host_outside_the_list
    dir, fetch = directory({})

    assert_nil(dir.public_key_for('evil.example.test'))
    assert_nil(dir.public_key_for('169.254.169.254'))
    assert_empty(fetch.calls)
  end

  # ⚠ サブドメインを名乗っても取りに行かない（完全一致）。
  def test_subdomains_are_not_in_the_list
    dir, fetch = directory({})

    assert_nil(dir.public_key_for('evil.mstdn.b-shock.org'))
    assert_empty(fetch.calls)
  end

  # ⚠ 大小・末尾のドットは揃える（[Relay::PresetServers.normalize] と同じ）。
  def test_normalizes_the_host
    dir, = directory({MASTODON_URL => mastodon_body('BMastodonKey')})

    assert_equal('BMastodonKey', dir.public_key_for('Mstdn.B-Shock.org.'))
  end

  # --- 引けなかったとき ---------------------------------------------------

  def test_returns_nil_when_both_shapes_are_missing
    dir, = directory({MASTODON_URL => '{}', MASTODON_MISSKEY_URL => '{}'})

    assert_nil(dir.public_key_for('mstdn.b-shock.org'))
  end

  def test_returns_nil_on_broken_json
    dir, = directory({MASTODON_URL => 'not json', MASTODON_MISSKEY_URL => '[]'})

    assert_nil(dir.public_key_for('mstdn.b-shock.org'))
  end

  # ⚠ **HTTP が落ちても例外を外へ出さない**（push の受け口を巻き込まない）。
  def test_never_raises_when_http_fails
    raiser = proc {raise Errno::ECONNREFUSED}
    dir, = directory({MASTODON_URL => raiser, MASTODON_MISSKEY_URL => raiser})

    assert_nil(dir.public_key_for('mstdn.b-shock.org'))
  end

  # --- キャッシュ ---------------------------------------------------------

  def test_caches_the_key
    dir, fetch = directory({MASTODON_URL => mastodon_body('BMastodonKey')})
    3.times {dir.public_key_for('mstdn.b-shock.org')}

    assert_equal(1, fetch.calls.size)
  end

  def test_refetches_after_the_ttl
    now = 1000.0
    dir, fetch = directory(
      {MASTODON_URL => mastodon_body('BMastodonKey')}, ttl: 60, clock: -> {now}
    )
    dir.public_key_for('mstdn.b-shock.org')
    now += 61
    dir.public_key_for('mstdn.b-shock.org')

    assert_equal(2, fetch.calls.size)
  end

  # ⚠ **落ちているサーバーを叩き続けない。**
  def test_caches_the_failure_for_a_shorter_window
    now = 1000.0
    dir, fetch = directory(
      {}, ttl: 3600, negative_ttl: 60, clock: -> {now}
    )
    dir.public_key_for('mstdn.b-shock.org')
    before = fetch.calls.size
    dir.public_key_for('mstdn.b-shock.org')

    assert_equal(before, fetch.calls.size)

    now += 61
    dir.public_key_for('mstdn.b-shock.org')

    assert_operator(fetch.calls.size, :>, before)
  end

  def test_reset_clears_the_cache
    dir, fetch = directory({MASTODON_URL => mastodon_body('BMastodonKey')})
    dir.public_key_for('mstdn.b-shock.org')
    dir.reset!
    dir.public_key_for('mstdn.b-shock.org')

    assert_equal(2, fetch.calls.size)
  end
end
