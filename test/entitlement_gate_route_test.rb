require_relative 'support/request_test_case'

# 認可ゲートが `/register` と `/push` の両方を通ること (capsicum#597 / #60)。
#
# ⚠⚠ **フェーズ 2 は挙動不変。**既定（enforce off）で既存の登録も配送も 1mm も
# 変わらないことを固定したうえで、閉じた側の経路を env で開けて検査する。
class EntitlementGateRouteTest < RequestTestCase
  VALID = {
    token: 'device-token', device_type: 'ios',
    account: 'alice@mastodon.social', server: 'mastodon.social',
    device_id: 'gate-device-1'
  }.freeze

  # ⚠ **env を戻す。**戻さないと後続のテストが「閉じた」状態で走る。
  def with_enforce
    previous = ENV.fetch('RELAY_ENTITLEMENT_ENFORCE', nil)
    ENV['RELAY_ENTITLEMENT_ENFORCE'] = 'true'
    yield
  ensure
    if previous.nil?
      ENV.delete('RELAY_ENTITLEMENT_ENFORCE')
    else
      ENV['RELAY_ENTITLEMENT_ENFORCE'] = previous
    end
  end

  # --- 既定（enforce off）＝挙動不変 --------------------------------------

  def test_register_is_unchanged_by_default
    post_json('/register', VALID)

    assert_equal(201, last_response.status)
    refute_empty(json_response['push_token'].to_s)
  end

  def test_push_is_unchanged_by_default
    push_token = register_subscription(**VALID.slice(:token, :device_type, :account, :server))['push_token']
    post("/push/#{push_token}", 'body', {'CONTENT_TYPE' => 'application/octet-stream'})

    # apns / fcm は fixture で未設定なので 503（not configured）まで進む。
    # ⚠ **410 ではない**ことが要点（ゲートで止まっていない）。
    refute_equal(410, last_response.status)
  end

  def test_gate_reason_is_enforce_off_by_default
    post_json('/register', VALID)

    assert_equal(
      1,
      metrics.value('relay_entitlement_gate_total',
        {route: 'register', decision: 'allow', reason: 'enforce_off'}),
    )
  end

  # --- 閉じた側（enforce on） ---------------------------------------------

  # ⚠⚠ **止めるのは `/push`。**410 を返すと fedi サーバーが購読を掃除する。
  def test_push_returns_410_when_denied
    push_token = register_subscription(**VALID.slice(:token, :device_type, :account, :server))['push_token']

    with_enforce do
      post("/push/#{push_token}", 'body', {'CONTENT_TYPE' => 'application/octet-stream'})
    end

    assert_equal(410, last_response.status)
    assert_equal('Entitlement required', json_response['error'])
  end

  # ⚠ **`subscriptions` の行は消さない。**購入が復活したら再登録で同じ行を使う。
  def test_denied_push_keeps_the_subscription_row
    push_token = register_subscription(**VALID.slice(:token, :device_type, :account, :server))['push_token']

    with_enforce do
      post("/push/#{push_token}", 'body', {'CONTENT_TYPE' => 'application/octet-stream'})
    end

    refute_nil(database.find_by_push_token(push_token))
  end

  # ⚠ 401（シークレット違い）と区別できる形で返す。
  def test_register_returns_403_when_denied
    with_enforce {post_json('/register', VALID)}

    assert_equal(403, last_response.status)
    assert_equal('entitlement_required', json_response['reason'])
  end

  # ⚠⚠ **登録してから判定する。**行を作らずに拒むと、ゲートを閉じた瞬間に
  # 「誰が止まったか」が DB から分からなくなる（#59 の観測の母数が消える）。
  def test_denied_register_still_records_the_row
    with_enforce {post_json('/register', VALID)}

    assert_equal(403, last_response.status)
    refute_nil(
      database.find_by_device(VALID[:account], VALID[:server], VALID[:device_id]),
      '観測のために行は残す',
    )
    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'no', entitlement: 'none', token: 'none'}),
      '#59 の観測も止まらない',
    )
  end

  # ⚠⚠ **プリセットは巻き込まない**（#60 の「絶対に守る 2 点」の 1）。
  def test_preset_host_passes_even_when_enforcing
    preset = VALID.merge(account: 'pooza@mstdn.b-shock.org', server: 'mstdn.b-shock.org')

    with_enforce {post_json('/register', preset)}

    assert_equal(201, last_response.status)
    assert_equal(
      1,
      metrics.value('relay_entitlement_gate_total',
        {route: 'register', decision: 'allow', reason: 'preset'}),
    )
  end

  def test_active_entitlement_passes_when_enforcing
    post_json('/entitlements', {
      store: 'apple', purchase_id: 'gate-purchase-1', device_id: VALID[:device_id]
    })
    raw = SQLite3::Database.new(safe_db_path)
    raw.execute("UPDATE entitlements SET status = 'active'")
    raw.close

    with_enforce {post_json('/register', VALID)}

    assert_equal(201, last_response.status)
    assert_equal(
      1,
      metrics.value('relay_entitlement_gate_total',
        {route: 'register', decision: 'allow', reason: 'entitled'}),
    )
  end

  # ⚠⚠ 誰でも作れる行（#58）なので通さない。
  def test_unverified_entitlement_does_not_pass
    post_json('/entitlements', {
      store: 'apple', purchase_id: 'gate-purchase-2', device_id: VALID[:device_id]
    })

    with_enforce {post_json('/register', VALID)}

    assert_equal(403, last_response.status)
  end

  # --- 既存の 410（stale push_token）と混ざらないこと ----------------------

  # ⚠ 知らない push_token の 410 は**ゲートとは別の理由**。文面で区別できる。
  def test_unknown_push_token_410_is_distinguishable
    post('/push/nope', 'body', {'CONTENT_TYPE' => 'application/octet-stream'})

    assert_equal(410, last_response.status)
    assert_equal('Unknown push token', json_response['error'])
  end

  private

  def metrics
    return Relay::App.settings.metrics
  end
end
