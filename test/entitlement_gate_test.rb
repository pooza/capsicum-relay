require_relative 'test_helper'
require 'relay/entitlement_gate'

# 有償リレーの認可ゲート (capsicum#597 / #60)。**フェーズ 2。**
#
# ⚠⚠ **既定では何も閉じない。**ここで固定したいのは「判定が 1 か所にある」
# 「既定で許可」「fail-open」「プリセットは判定に入る前に抜ける」の 4 点。
class EntitlementGateTest < Minitest::Test
  G = Relay::EntitlementGate

  # `entitlement_tokens_for_device` と `servers_for_device` だけを持つ最小の DB 代役。
  class FakeDatabase
    def initialize(rows, servers = [])
      @rows = rows
      @servers = servers
    end

    def entitlement_tokens_for_device(_device_id) = @rows
    def servers_for_device(_device_id) = @servers
  end

  # 呼ばれたら落ちる DB（fail-open の検査用）。
  class BrokenDatabase
    def entitlement_tokens_for_device(_device_id)
      raise SQLite3::BusyException, 'database is locked'
    end

    def servers_for_device(_device_id)
      raise SQLite3::BusyException, 'database is locked'
    end
  end

  ON = {'RELAY_ENTITLEMENT_ENFORCE' => 'true'}.freeze
  OFF = {}.freeze

  def sub(server: 'mastodon.social', device_id: 'd1')
    return {'server' => server, 'device_id' => device_id, 'account' => "a@#{server}"}
  end

  # ⚠ 同じ端末の購読先 (#82) は `servers:` で渡す。引数を増やさないため DB 代役に持たせる。
  def decide(env: ON, rows: [], database: nil, verification: G::PRESET_NOT_CHECKED, **overrides)
    servers = overrides.delete(:servers) || []
    return G.decide(
      subscription: sub(**overrides),
      database: database || FakeDatabase.new(rows, servers),
      preset_verification: verification,
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

  # --- プリセットと外部を併用する端末 (#82) ---------------------------------

  # ⚠⚠ **#82 の核心。**行の `server` だけで決めると、併用者の外部側が止まる。
  def test_external_row_passes_when_the_device_has_a_preset
    assert_equal(
      [true, 'preset_device'],
      decide(servers: ['mastodon.social', 'mstdn.b-shock.org'], rows: []),
    )
  end

  # ⚠ 表記の揺れは [Relay::PresetServers.preset?] が揃える。
  def test_preset_device_tolerates_spelling_variants
    assert_equal([true, 'preset_device'], decide(servers: ['MSTDN.B-Shock.org.']))
  end

  def test_external_only_device_still_needs_an_entitlement
    assert_equal(
      [false, 'no_entitlement'],
      decide(servers: ['mastodon.social', 'misskey.io'], rows: []),
    )
  end

  # ⚠ 旧クライアント（`device_id` 無し）は端末で束ねられない。
  def test_preset_device_needs_a_device_id
    assert_equal(
      [false, 'no_entitlement'],
      decide(device_id: nil, servers: ['mstdn.b-shock.org']),
    )
  end

  # ⚠⚠ **#69 は緩めない。**プリセットの行そのものへの署名無しの push は、
  # 同じ端末に別のプリセット行があっても止める。
  def test_unsigned_preset_row_is_not_rescued_by_the_device
    assert_equal(
      [false, 'preset_unsigned'],
      decide(
        server: 'mstdn.b-shock.org', verification: G::PRESET_UNSIGNED,
        servers: ['mstdn.b-shock.org', 'precure.ml']
      ),
    )
  end

  # --- プリセットの名乗りの裏取り (#69) -----------------------------------

  # ⚠⚠ **`/register` は検証しない。**叩くのはクライアント自身で fedi サーバーの
  # 署名が無い。⚠ **止めるのは `/push`** なので、ここを通しても穴は残らない。
  def test_not_checked_keeps_the_preset_shortcut
    assert_equal(
      [true, 'preset'],
      decide(server: 'mstdn.b-shock.org', verification: G::PRESET_NOT_CHECKED),
    )
  end

  def test_verified_preset_is_allowed
    assert_equal(
      [true, 'preset'],
      decide(server: 'mstdn.b-shock.org', verification: G::PRESET_VERIFIED),
    )
  end

  # ⚠⚠ **鍵が引けなかったのは「こちらの障害」なので fail-open。**
  # ただし理由を分けて、ゲートが効いていないことに気付けるようにする。
  def test_unavailable_key_fails_open
    allowed, reason = decide(server: 'mstdn.b-shock.org', verification: G::PRESET_UNAVAILABLE)

    assert(allowed, '鍵が引けないだけで本物のプリセットを止めない')
    assert_equal('preset_unverifiable', reason)
  end

  # ⚠⚠ **#69 の核心。**署名が無いのを fail-open にすると、**ヘッダを付けないだけで
  # 迂回できる**＝直したことにならない。
  def test_unsigned_preset_claim_loses_the_shortcut
    assert_equal(
      [false, 'preset_unsigned'],
      decide(server: 'mstdn.b-shock.org', verification: G::PRESET_UNSIGNED, rows: []),
    )
  end

  # ⚠⚠ **詐称。**別のサーバーの鍵で署名されている。
  def test_mismatched_key_loses_the_shortcut
    assert_equal(
      [false, 'preset_mismatch'],
      decide(server: 'mstdn.b-shock.org', verification: G::PRESET_MISMATCH, rows: []),
    )
  end

  # ⚠ **裏が取れなくても、購入していれば通る。**プリセットのホスト名で登録した
  # 購入者を巻き添えにしない。
  def test_a_failed_preset_claim_still_falls_through_to_the_entitlement
    assert_equal(
      [true, 'entitled'],
      decide(
        server: 'mstdn.b-shock.org',
        verification: G::PRESET_UNSIGNED,
        rows: [{'status' => 'active'}],
      ),
    )
  end

  # ⚠ 理由は `no_entitlement` に溶かさない。「利用権が無い」と「プリセットを
  # 詐称した」は対処がまったく違う。
  def test_the_denial_reason_names_the_preset_failure
    _, reason = decide(server: 'mstdn.b-shock.org', verification: G::PRESET_MISMATCH)

    refute_equal('no_entitlement', reason)
  end

  # ⚠ 非プリセットの判定は 1mm も変わらない（検証の値に関係なく利用権だけを見る）。
  def test_verification_does_not_affect_non_preset_hosts
    assert_equal([false, 'no_entitlement'], decide(verification: G::PRESET_MISMATCH))
    assert_equal(
      [true, 'entitled'],
      decide(verification: G::PRESET_UNSIGNED, rows: [{'status' => 'active'}]),
    )
  end

  # ⚠ 知らない値は**署名が無い**側へ倒す（黙って通さない）。
  def test_an_unknown_verification_value_is_not_a_shortcut
    assert_equal(
      [false, 'preset_unsigned'],
      decide(server: 'mstdn.b-shock.org', verification: :something_new),
    )
  end

  def test_non_preset_without_entitlement_is_denied
    assert_equal([false, 'no_entitlement'], decide(rows: []))
  end

  def test_non_preset_with_active_entitlement_is_allowed
    assert_equal([true, 'entitled'], decide(rows: [{'status' => 'active'}]))
  end

  # ⚠⚠ **支払い猶予は止める**（2026-10-03 pooza 判断・#63）。以前は通していた。
  # 状態と期限の組み合わせは entitlement_gate_period_test.rb。
  def test_unpaid_statuses_are_denied
    assert_equal([false, 'unpaid'], decide(rows: [{'status' => 'grace'}]))
  end

  # ⚠⚠ **これがゲートの核心。**`POST /entitlements` は共有シークレットしか見ておらず、
  # そのシークレットはバイナリから取り出せる（capsicum#1121）ので、⚠ **誰でも
  # `unverified` の行を作れる。**許可側に入れるとゲートが無意味になる。
  def test_unverified_is_not_entitled
    assert_equal([false, 'no_entitlement'], decide(rows: [{'status' => 'unverified'}]))
  end

  # ⚠ 理由は `expired`（`no_entitlement` と分ける・#63）。返金済みで期限の無い行も
  # ここに落ちる（詳細は entitlement_gate_period_test.rb）。
  def test_expired_and_revoked_are_not_entitled
    assert_equal([false, 'expired'], decide(rows: [{'status' => 'expired'}]))
    assert_equal([false, 'expired'], decide(rows: [{'status' => 'revoked'}]))
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
