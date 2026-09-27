require_relative 'test_helper'
require 'relay/entitlement_gate'

# 有償リレーの認可ゲート (capsicum#597 / #60)。**フェーズ 2。**
#
# ⚠⚠ **既定では何も閉じない。**ここで固定したいのは「判定が 1 か所にある」
# 「既定で許可」「fail-open」「プリセットは判定に入る前に抜ける」の 4 点。
class EntitlementGateTest < Minitest::Test
  G = Relay::EntitlementGate

  # `entitlement_tokens_for_device` だけを持つ最小の DB 代役。
  class FakeDatabase
    def initialize(rows) = @rows = rows
    def entitlement_tokens_for_device(_device_id) = @rows
  end

  # 呼ばれたら落ちる DB（fail-open の検査用）。
  class BrokenDatabase
    def entitlement_tokens_for_device(_device_id)
      raise SQLite3::BusyException, 'database is locked'
    end
  end

  ON = {'RELAY_ENTITLEMENT_ENFORCE' => 'true'}.freeze
  OFF = {}.freeze

  def sub(server: 'mastodon.social', device_id: 'd1')
    return {'server' => server, 'device_id' => device_id, 'account' => "a@#{server}"}
  end

  def decide(env: ON, rows: [], database: nil, **overrides)
    return G.decide(
      subscription: sub(**overrides),
      database: database || FakeDatabase.new(rows),
      env: env,
    )
  end

  # ⚠⚠ **いちばん大事な固定。**フェーズ 2 は挙動不変。
  def test_allows_everything_when_enforce_is_off
    assert_equal([true, 'enforce_off'], decide(env: OFF))
    assert_equal([true, 'enforce_off'], decide(env: OFF, device_id: nil))
  end

  def test_enforce_requires_the_exact_string_true
    assert_equal([true, 'enforce_off'], decide(env: {'RELAY_ENTITLEMENT_ENFORCE' => '1'}))
    assert_equal([true, 'enforce_off'], decide(env: {'RELAY_ENTITLEMENT_ENFORCE' => 'yes'}))
    assert_equal([true, 'enforce_off'], decide(env: {'RELAY_ENTITLEMENT_ENFORCE' => ''}))
    refute(G.enforce?(env: {'RELAY_ENTITLEMENT_ENFORCE' => 'TRUE'}))
  end

  # ⚠⚠ **プリセットは判定に入る前に抜ける**（#60 の「絶対に守る 2 点」の 1）。
  def test_preset_host_is_allowed_without_entitlement
    allowed, reason = decide(server: 'mstdn.b-shock.org', rows: [])

    assert(allowed)
    assert_equal('preset', reason)
  end

  # 「プリセットに 1 アカウント持てば全部無償」の穴は残す（2026-09-12 決定）。
  def test_preset_staging_host_is_allowed
    assert_equal([true, 'preset'], decide(server: 'st2.mstdn.b-shock.org'))
  end

  def test_non_preset_without_entitlement_is_denied
    assert_equal([false, 'no_entitlement'], decide(rows: []))
  end

  def test_non_preset_with_active_entitlement_is_allowed
    assert_equal([true, 'entitled'], decide(rows: [{'status' => 'active'}]))
  end

  # ⚠ 支払い猶予は通す（課金リトライ中に通知が止まると気付けない）。
  def test_grace_is_allowed
    assert_equal([true, 'entitled'], decide(rows: [{'status' => 'grace'}]))
  end

  # ⚠⚠ **これがゲートの核心。**`POST /entitlements` は共有シークレットしか見ておらず、
  # そのシークレットはバイナリから取り出せる（capsicum#1121）ので、⚠ **誰でも
  # `unverified` の行を作れる。**許可側に入れるとゲートが無意味になる。
  def test_unverified_is_not_entitled
    assert_equal([false, 'no_entitlement'], decide(rows: [{'status' => 'unverified'}]))
  end

  def test_expired_and_revoked_are_not_entitled
    assert_equal([false, 'no_entitlement'], decide(rows: [{'status' => 'expired'}]))
    assert_equal([false, 'no_entitlement'], decide(rows: [{'status' => 'revoked'}]))
  end

  # ⚠ 上流が status を増やしたときに勝手に通さない。
  def test_unknown_status_is_not_entitled
    assert_equal([false, 'no_entitlement'], decide(rows: [{'status' => 'something_new'}]))
  end

  # 1 端末が複数の購入にぶら下がりうる（買い直し・別ストア）。
  def test_one_valid_entitlement_among_many_is_enough
    allowed, = decide(rows: [{'status' => 'expired'}, {'status' => 'active'}])

    assert(allowed)
  end

  # ⚠⚠ **旧クライアントは止まる。**`device_id` を送らない行は利用権を引けない。
  # 実測では該当 0 人だが、⚠ **閉じる前に測り直すこと**（設計書 2-4）。
  def test_row_without_device_id_is_denied_when_non_preset
    assert_equal([false, 'no_entitlement'], decide(device_id: nil))
    assert_equal([false, 'no_entitlement'], decide(device_id: ''))
  end

  # ⚠ ただしプリセットなら device_id が無くても通る（判定の前に抜けるので）。
  def test_row_without_device_id_is_allowed_when_preset
    assert_equal([true, 'preset'], decide(server: 'precure.ml', device_id: nil))
  end

  # ⚠⚠ **fail-open**（#60 の「絶対に守る 2 点」の 2）。課金判定の失敗で無償
  # ユーザーの通知が止まるのは取り返しがつかない。
  def test_fails_open_when_the_lookup_raises
    allowed, reason = decide(database: BrokenDatabase.new)

    assert(allowed, '判定が落ちたら通す')
    assert_equal('error', reason, '通したことに気付けるよう理由を分ける')
  end

  # ⚠ 行の形が想定と違っても落ちない（fail-open で拾う）。
  def test_fails_open_on_malformed_rows
    allowed, = G.decide(
      subscription: {'server' => nil, 'device_id' => 'd1'},
      database: FakeDatabase.new([nil]),
      env: ON,
    )

    assert(allowed)
  end
end
