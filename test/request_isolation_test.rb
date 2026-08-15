require_relative 'support/request_test_case'

# 🔴 request テストが**自分の一時 DB 以外を絶対に消さない**ことの回帰テスト
# （Codex P1・PR #40）。
#
# `setup` は毎回 `DELETE FROM` でテーブルを空にする。シェルに `RELAY_DB_PATH` が
# 設定された環境で `rake test` を叩いたときにそこを消してしまう、というのが
# 指摘の中身だった。
class RequestIsolationTest < RequestTestCase
  def test_uses_the_tmpdir_created_by_this_process
    assert(
      ENV.fetch('RELAY_DB_PATH').start_with?("#{RELAY_TEST_DB_DIR}/"),
      'テストは自分で作った一時ディレクトリの DB を見ること',
    )
  end

  # 設定も固定する（本番の秘密情報をテストに読ませない）。
  def test_uses_the_fixture_settings
    assert_equal(
      File.expand_path('fixtures/settings.yml', __dir__),
      ENV.fetch('RELAY_CONFIG_PATH'),
    )
    assert_equal('test-secret', Relay::BaseApp.settings.config['shared_secret'])
  end

  # 多重防御。env 固定が将来ほどけても、外の DB は truncate しない。
  def test_refuses_to_truncate_a_database_outside_the_tmpdir
    original = ENV.fetch('RELAY_DB_PATH')
    ENV['RELAY_DB_PATH'] = '/tmp/definitely-not-ours.sqlite3'

    error = assert_raises(RuntimeError) {safe_db_path}

    assert_match('refusing to truncate', error.message)
  ensure
    ENV['RELAY_DB_PATH'] = original
  end

  # ⚠ prefix 一致だけだと `/tmp/xxx-evil` のような隣接パスを通してしまう。
  # 区切りまで含めて見ていることを固定する。
  def test_sibling_directory_with_the_same_prefix_is_rejected
    original = ENV.fetch('RELAY_DB_PATH')
    ENV['RELAY_DB_PATH'] = "#{RELAY_TEST_DB_DIR}-evil/relay.sqlite3"

    assert_raises(RuntimeError) {safe_db_path}
  ensure
    ENV['RELAY_DB_PATH'] = original
  end
end
