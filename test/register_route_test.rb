require_relative 'support/request_test_case'

# POST /register / DELETE /register/:id (#34)。
#
# route を別クラスへ割る前後で挙動が変わらないことを担保するのが主目的なので、
# 正常系より**入口のバリデーション**（認証・必須項目・device_type・WNS URI）を
# 厚く固定する。ここが緩むと DB や push 経路に不正な値が流れ込む。
class RegisterRouteTest < RequestTestCase
  VALID = {
    token: 'device-token',
    device_type: 'ios',
    account: 'alice@example.test',
    server: 'example.test',
  }.freeze

  def test_requires_secret
    post('/register', VALID.to_json, {'CONTENT_TYPE' => 'application/json'})

    assert_equal(401, last_response.status)
  end

  def test_rejects_wrong_secret
    post_json('/register', VALID, secret: 'nope')

    assert_equal(401, last_response.status)
  end

  def test_registers
    post_json('/register', VALID)

    assert_equal(201, last_response.status)
    assert_equal('alice@example.test', json_response['account'])
    assert_equal('ios', json_response['device_type'])
  end

  # push_token は relay が発行する。capsicum はこれを endpoint に組み立てる。
  def test_returns_push_token
    post_json('/register', VALID)

    refute_empty(json_response['push_token'].to_s)
  end

  def test_rejects_missing_fields
    post_json('/register', VALID.except(:server))

    assert_equal(400, last_response.status)
    assert_match('server', json_response['error'])
  end

  # 空文字は「送っていない」と同じ扱い。
  def test_rejects_blank_fields
    post_json('/register', VALID.merge(account: ''))

    assert_equal(400, last_response.status)
  end

  def test_rejects_unknown_device_type
    post_json('/register', VALID.merge(device_type: 'symbian'))

    assert_equal(400, last_response.status)
  end

  def test_accepts_all_four_device_types
    ['ios', 'android', 'macos'].each do |type|
      post_json('/register', VALID.merge(device_type: type, token: "token-#{type}"))

      assert_equal(201, last_response.status, type)
    end
  end

  # ⚠ windows の token は WNS Channel URI。任意ホストを保存できると /push で
  # そこへ Bearer + payload 付き POST をさせられる (SSRF・#21)。入口で弾く。
  def test_rejects_non_wns_channel_uri_for_windows
    post_json(
      '/register',
      VALID.merge(device_type: 'windows', token: 'https://evil.example.test/hook'),
    )

    assert_equal(400, last_response.status)
    assert_match('WNS', json_response['error'])
  end

  def test_accepts_wns_channel_uri
    post_json(
      '/register',
      VALID.merge(
        device_type: 'windows',
        token: 'https://db5p.notify.windows.com/?token=abc',
      ),
    )

    assert_equal(201, last_response.status)
  end

  def test_rejects_invalid_json
    post_json('/register', 'not json at all')

    assert_equal(400, last_response.status)
    assert_equal('Invalid JSON', json_response['error'])
  end

  def test_unregisters
    sub = register_subscription

    delete("/register/#{sub['id']}", {}, auth_headers)

    assert_equal(200, last_response.status)
    assert_equal(0, database.count)
  end

  # ⚠⚠ #91: 消した行の中身を返さない。行には端末トークンが入っており、この口は
  # 連番の id と共有シークレットだけで叩けるので、総当たりで読めてしまう。
  def test_unregister_does_not_return_the_deleted_row
    sub = register_subscription

    delete("/register/#{sub['id']}", {}, auth_headers)

    assert_equal({'id' => sub['id']}, json_response)
    refute_includes(last_response.body, sub['token'], '端末トークンが応答に載っている')
    ['token', 'device_token', 'account', 'server', 'device_id'].each do |key|
      refute(json_response.key?(key), "#{key} が応答に載っている")
    end
  end

  def test_unregister_requires_secret
    sub = register_subscription

    delete("/register/#{sub['id']}")

    assert_equal(401, last_response.status)
    assert_equal(1, database.count)
  end

  def test_unregister_returns_404_for_unknown_id
    delete('/register/9999', {}, auth_headers)

    assert_equal(404, last_response.status)
  end

  # --- 利用権の観測 (capsicum#597 / #59) ----------------------------------
  #
  # ⚠⚠ **この Issue では誰も拒まない。**受け取って記録するだけ。

  # ⚠⚠ **いちばん大事な固定。**token を持たないクライアント（無償のプリセット
  # ユーザーが大多数）が従来どおり成功する。
  def test_registers_without_entitlement_token
    post_json('/register', VALID)

    assert_equal(201, last_response.status)
    refute_empty(json_response['push_token'].to_s)
    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'no', entitlement: 'none', token: 'none'}),
    )
  end

  # #82（PR #83 の Codex P2）: enforce off のまま測る観測も、ゲートと同じく
  # 端末単位のプリセットを数える。⚠ でないと閉じたときに止まる人を多く見積もる。
  def test_external_registration_on_a_preset_device_is_not_a_stop_candidate
    device = {device_id: 'observe-device-1'}
    post_json('/register', VALID.merge(device, account: 'p@mstdn.b-shock.org',
      server: 'mstdn.b-shock.org'))
    post_json('/register', VALID.merge(device))

    assert_equal(201, last_response.status)
    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'device', entitlement: 'none', token: 'none'}),
    )
  end

  # ⚠ 知らない token を送られても拒まない（拒むのはフェーズ 2 以降）。
  def test_registers_with_unknown_entitlement_token
    post_json('/register', VALID.merge(device_id: 'd1', entitlement_token: 'bogus'))

    assert_equal(201, last_response.status)
    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'no', entitlement: 'none', token: 'unknown'}),
    )
  end

  def test_records_matching_entitlement_token
    token = issue_entitlement(device_id: 'd1')
    post_json('/register', VALID.merge(device_id: 'd1', entitlement_token: token))

    assert_equal(201, last_response.status)
    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'no', entitlement: 'unverified', token: 'ok'}),
    )
  end

  # ⚠⚠ ゲート（#60）は `subscriptions.device_id` から引くので、この端末は
  # フェーズ 3 で止まる。token を送れているのに止まる形を先に数える。
  def test_records_token_belonging_to_another_device
    token = issue_entitlement(device_id: 'other-device')
    post_json('/register', VALID.merge(device_id: 'd1', entitlement_token: token))

    assert_equal(201, last_response.status)
    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'no', entitlement: 'none', token: 'mismatch'}),
    )
  end

  # ⚠ **利用権は token の申告ではなく device_id から引く。**token を送ってこない
  # クライアントでも、その端末に利用権があれば観測に出る。
  def test_finds_entitlement_by_device_id_without_claimed_token
    issue_entitlement(device_id: 'd1')
    post_json('/register', VALID.merge(device_id: 'd1'))

    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'no', entitlement: 'unverified', token: 'none'}),
    )
  end

  def test_records_preset_host
    post_json('/register', VALID.merge(
      account: 'pooza@mstdn.b-shock.org', server: 'mstdn.b-shock.org',
    ))

    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'yes', entitlement: 'none', token: 'none'}),
    )
  end

  # ⚠ 旧クライアント（device_id を送らない）でも落ちない。
  def test_registers_without_device_id_and_with_token
    token = issue_entitlement(device_id: 'other-device')
    post_json('/register', VALID.merge(entitlement_token: token))

    assert_equal(201, last_response.status)
    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'no', entitlement: 'none', token: 'mismatch'}),
    )
  end

  # 空文字は「送っていない」と同じ扱い（他の項目と揃える）。
  def test_blank_entitlement_token_is_treated_as_absent
    post_json('/register', VALID.merge(entitlement_token: ''))

    assert_equal(201, last_response.status)
    assert_equal(
      1,
      metrics.value('relay_register_entitlement_total',
        {preset: 'no', entitlement: 'none', token: 'none'}),
    )
  end

  private

  def metrics
    return Relay::App.settings.metrics
  end

  def issue_entitlement(device_id:)
    post_json('/entitlements', {
      store: 'apple', purchase_id: "purchase-#{device_id}", device_id: device_id
    })
    return JSON.parse(last_response.body)['token']
  end
end
