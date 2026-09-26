require_relative 'support/request_test_case'

# POST /entitlements（capsicum#597 / #58・フェーズ 1）。
#
# ⚠⚠ **この Issue では誰も拒まない。**ゲートはフェーズ 2（#60）、レシート検証は
# フェーズ 3（#61 / #62）。ここで固定したいのは「発行と保存が動く」ことと、
# **既存の挙動が 1mm も変わっていない**ことの 2 つ。
class EntitlementRouteTest < RequestTestCase
  VALID = {
    store: 'apple',
    purchase_id: 'original-transaction-id-1',
    product_id: 'org.b-shock.capsicum.relay.monthly',
    device_id: 'device-install-1',
  }.freeze

  def test_requires_secret
    post('/entitlements', VALID.to_json, {'CONTENT_TYPE' => 'application/json'})

    assert_equal(401, last_response.status)
  end

  def test_issues_token
    post_json('/entitlements', VALID)

    assert_equal(201, last_response.status)
    refute_empty(json_response['token'].to_s)
    assert_equal('apple', json_response['store'])
    assert_equal(VALID[:purchase_id], json_response['purchase_id'])
  end

  # ⚠⚠ フェーズ 1 は検証していないので active にしない。ゲート（#60）が
  # unverified を許可側に入れたら、誰でも作れる行が利用権として通ってしまう。
  def test_new_entitlement_is_unverified
    post_json('/entitlements', VALID)

    assert_equal('unverified', json_response['status'])
    assert_nil(json_response['expires_at'])
  end

  # ⚠ token から購入内容が読めてはいけない（#58 の完了条件）。
  def test_token_is_opaque
    post_json('/entitlements', VALID)
    token = json_response['token']

    refute_includes(token, VALID[:purchase_id])
    refute_includes(token, VALID[:product_id])
    refute_includes(token, VALID[:device_id])
    refute_includes(token, 'apple')
    # 32 バイトの urlsafe base64。推測できない長さであることを固定する。
    assert_operator(token.length, :>=, 40)
  end

  def test_tokens_differ_between_devices
    post_json('/entitlements', VALID)
    first = json_response['token']
    post_json('/entitlements', VALID.merge(device_id: 'device-install-2'))
    second = json_response['token']

    refute_equal(first, second)
    assert_equal(2, database.entitlement_token_count)
    assert_equal(1, database.entitlement_count, '購入は 1 つ')
  end

  # ⚠ アプリの起動ごとに token が増えると、端末単位の無効化（#57）が
  # 「どれを消せばいいのか分からない」状態になる。
  def test_reissue_for_same_device_returns_same_token
    post_json('/entitlements', VALID)
    first = json_response['token']
    post_json('/entitlements', VALID)

    assert_equal(201, last_response.status)
    assert_equal(first, json_response['token'])
    assert_equal(1, database.entitlement_token_count)
  end

  # ⚠⚠ フェーズ 3 の検証結果を、クライアントの再発行要求で巻き戻さない
  # （アプリを再起動しただけで有効な購入が無効に見える）。
  def test_reissue_does_not_reset_verified_status
    post_json('/entitlements', VALID)
    token = json_response['token']
    raw = SQLite3::Database.new(safe_db_path)
    raw.execute(
      "UPDATE entitlements SET status = 'active', expires_at = '2026-12-31 00:00:00'",
    )
    raw.close

    post_json('/entitlements', VALID)

    assert_equal('active', json_response['status'])
    assert_equal('2026-12-31 00:00:00', json_response['expires_at'])
    assert_equal(token, json_response['token'])
  end

  def test_rejects_unknown_store
    post_json('/entitlements', VALID.merge(store: 'steam'))

    assert_equal(400, last_response.status)
    assert_match('store', json_response['error'])
  end

  # ⚠ Linux は買える経路が無いので、ストアとして受け付けない（設計書 未決事項 7）。
  def test_rejects_linux_as_store
    post_json('/entitlements', VALID.merge(store: 'linux'))

    assert_equal(400, last_response.status)
  end

  def test_requires_device_id
    post_json('/entitlements', VALID.except(:device_id))

    assert_equal(400, last_response.status)
    assert_match('device_id', json_response['error'])
  end

  def test_requires_purchase_id
    post_json('/entitlements', VALID.except(:purchase_id))

    assert_equal(400, last_response.status)
  end

  # product_id は任意（ストアによっては後から分かる）。
  def test_product_id_is_optional
    post_json('/entitlements', VALID.except(:product_id))

    assert_equal(201, last_response.status)
    assert_nil(json_response['product_id'])
  end

  # ⚠ 内部 id を返すと「id で引ける」と誤解される導線ができる。
  def test_does_not_return_internal_id
    post_json('/entitlements', VALID)

    refute(json_response.key?('id'))
    refute(json_response.key?('entitlement_id'))
  end

  # ⚠⚠ **既存の挙動を 1mm も変えない**（#58 の完了条件）。
  def test_register_still_works_without_any_entitlement
    sub = register_subscription

    assert_equal(201, last_response.status)
    refute_empty(sub['push_token'].to_s)
    assert_equal(0, database.entitlement_token_count)
  end

  def test_push_token_lookup_path_from_device_id
    post_json('/entitlements', VALID)
    token = json_response['token']

    # #57 の 2-4 の経路: subscriptions.device_id → entitlement_tokens.device_id
    found = database.entitlement_tokens_for_device(VALID[:device_id])

    assert_equal([token], found.map {|row| row['token']})
  end

  # ⚠ device_id を持たない旧クライアントの行は利用権を引けない（#57 の 2-4）。
  # その状態で例外にせず空を返すことを固定する。
  def test_lookup_with_blank_device_id_is_empty
    post_json('/entitlements', VALID)

    assert_empty(database.entitlement_tokens_for_device(nil))
    assert_empty(database.entitlement_tokens_for_device(''))
  end

  # ⚠ 1 購入あたりの端末数に上限を設けない（#57）。件数は記録する。
  def test_no_device_limit_per_purchase
    5.times {|i| post_json('/entitlements', VALID.merge(device_id: "device-#{i}"))}

    assert_equal(201, last_response.status)
    assert_equal(
      5,
      database.entitlement_tokens_for_purchase('apple', VALID[:purchase_id]).size,
    )
  end

  def test_find_entitlement_token_joins_purchase_status
    post_json('/entitlements', VALID)
    row = database.find_entitlement_token(json_response['token'])

    assert_equal('apple', row['store'])
    assert_equal('unverified', row['status'])
    assert_equal(VALID[:device_id], row['device_id'])
  end

  def test_find_unknown_token_is_nil
    assert_nil(database.find_entitlement_token('nope'))
  end
end
