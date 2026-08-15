require_relative 'test_helper'
require 'lib/relay/revision'
require 'lib/relay/sentry_setup'

# #37 稼働中の commit SHA の解決。
#
# `/health` の `revision` と Sentry の `release` が**同じ文字列**であることが
# この値の主用途なので、両者が同じ [Relay::Revision] を通ることまで固定する。
# 片方だけ別ロジックに戻ると、突き合わせの前に変換が要る値に静かに戻る。
class RevisionTest < Minitest::Test
  def teardown
    Relay::Revision.reset!
  end

  def test_env_is_used_when_present
    sha = Relay::Revision.resolve(
      env: {'SENTRY_RELEASE' => 'abc123'}, head: 'deadbeef',
    )

    assert_equal('abc123', sha)
  end

  def test_git_head_is_used_when_env_is_absent
    assert_equal('deadbeef', Relay::Revision.resolve(env: {}, head: 'deadbeef'))
  end

  # env が空文字（未設定と同義の設定ミス）でも git へ落ちる。
  def test_blank_env_falls_back_to_git
    sha = Relay::Revision.resolve(env: {'SENTRY_RELEASE' => ''}, head: 'deadbeef')

    assert_equal('deadbeef', sha)
  end

  # git チェックアウト外・git 未導入。名乗れないのは異常ではないので nil を
  # 返し、`/health` は null を出す（落とさない）。
  def test_returns_nil_when_nothing_is_available
    assert_nil(Relay::Revision.resolve(env: {}, head: ''))
  end

  def test_surrounding_whitespace_is_stripped
    assert_equal('deadbeef', Relay::Revision.resolve(env: {}, head: "deadbeef\n"))
  end

  # `/health` は監視から定期的に叩かれる。毎回 `git rev-parse` を fork しない。
  def test_current_is_memoized
    Relay::Revision.reset!
    first = Relay::Revision.current

    assert_same(first, Relay::Revision.current)
  end

  # 本番の実体（git チェックアウト）では実際に名乗れる。ここが落ちるなら
  # デプロイ形態が変わった合図。
  def test_current_resolves_in_this_checkout
    omit('SENTRY_RELEASE が設定された環境') unless ENV.fetch('SENTRY_RELEASE', '').empty?
    Relay::Revision.reset!

    assert_match(/\A[0-9a-f]{40}\z/, Relay::Revision.current)
  end

  # Sentry の release と `/health` の revision を同じ値に保つ (#37 の主目的)。
  def test_sentry_release_is_the_same_value
    assert_equal(Relay::Revision.current, Relay::SentrySetup.detect_release)
  end
end
