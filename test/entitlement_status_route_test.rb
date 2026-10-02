require_relative 'support/request_test_case'

# GET /entitlements（#80・capsicum#1123 の前提）。
#
# ⚠⚠ **`POST` を状態確認に使い回さないための口。**あちらは upsert なので冪等では
# あるが、呼ぶたびに `relay_entitlement_token_total` が増え `entitlement.issued` が
# 出る —— **「発行の回数」を数えている counter が「画面を開いた回数」に汚染され、
# ゲートを閉じてよいかの判断材料が濁る。**
#
# ⚠ ここで固定したいのは 4 つ。
#
# 1. 手元の token から**いまの状態**が読める
# 2. ⚠⚠ **metrics もログも増えない**（この口の存在理由そのもの）
# 3. ⚠ **知らない token は 404**（「失効」と混ぜない —— クライアントから見て
#    「端末の保存が壊れた」と「解約された」は別の状況で、案内が違う）
# 4. 🔴 **token を URL に載せない**（nginx の access log に平文で残る・PR #81 の
#    Codex P2）。⚠ **ヘッダで受ける。**
class EntitlementStatusRouteTest < RequestTestCase
  VALID = {
    store: 'apple',
    purchase_id: 'original-transaction-id-status',
    product_id: 'org.b-shock.capsicum.relay.monthly',
    device_id: 'device-install-status',
  }.freeze

  def issue
    post_json('/entitlements', VALID)
    return json_response['token']
  end

  # 🔴🔴 **ヘッダの値を `ASCII-8BIT` で渡す（2026-09-28 の実測に合わせる）。**
  #
  # **Puma / Rack がヘッダから作る String はバイナリ**で、⚠⚠ **そのまま SQLite へ
  # バインドすると TEXT ではなく BLOB になり、行があっても永久に一致しない。**
  #
  # ⚠⚠⚠ **素の String（UTF-8）で渡すと、この検査は壊れた実装でも緑になる** ——
  # 実際にそう書いてしまい、**実装が 1 件も引けないまま検査だけ通っていた。**
  # Rack::Test は env をそのまま使うので、**実 HTTP の条件はこちらで作る。**
  def get_status(token, secret: SECRET)
    return get('/entitlements', {}, auth_headers(secret: secret).merge(
      'HTTP_X_ENTITLEMENT_TOKEN' => token.dup.force_encoding(Encoding::BINARY),
    ))
  end

  def test_requires_secret
    token = issue
    get('/entitlements', {}, {'HTTP_X_ENTITLEMENT_TOKEN' => token})

    assert_equal(401, last_response.status)
  end

  def test_reads_the_current_state
    token = issue
    get_status(token)

    assert_equal(200, last_response.status)
    assert_equal(token, json_response['token'])
    assert_equal('apple', json_response['store'])
    assert_equal(VALID[:product_id], json_response['product_id'])
    # ⚠ フェーズ 3 の検証が通っていなければ unverified のまま（fail-open）。
    refute_empty(json_response['status'].to_s)
  end

  # ⚠ クライアントの `EntitlementToken.fromRelay` をそのまま使えるように、
  # **`POST` と同じ形**で返す。鍵が欠けると手元の値が黙って null になる。
  def test_returns_the_same_shape_as_the_post
    token = issue
    issued = json_response
    get_status(token)

    assert_equal(issued.keys.sort, json_response.keys.sort)
  end

  # ⚠⚠ **この口の存在理由。**増えたら `POST` を使い回すのと変わらない。
  def test_does_not_count_as_an_issuance
    token = issue
    before = metrics_value('relay_entitlement_token_total')
    3.times {get_status(token)}

    assert_equal(before, metrics_value('relay_entitlement_token_total'))
  end

  # ⚠ 「知らない」と「失効」を混ぜない。
  def test_unknown_token_is_not_found
    get_status('there-is-no-such-token')

    assert_equal(404, last_response.status)
  end

  # 🔴 **token を URL に載せる形を残さない。**`config/nginx.conf.sample` は素の
  # `access_log` を有効にしており、**リクエスト行に完全なパスが残る** ——
  # ⚠⚠ **token はそのまま利用権として使える**ので、平文でログに溜まる。
  def test_the_token_is_not_accepted_in_the_path
    token = issue
    get("/entitlements/#{token}", {}, auth_headers)

    refute_equal(200, last_response.status, 'パスに載せた token を受け付けない')
  end

  # ⚠ ヘッダが無ければ 400（404 にすると「知らない token」と混ざる）。
  def test_requires_the_token_header
    get('/entitlements', {}, auth_headers)

    assert_equal(400, last_response.status)
  end

  # --- entitled / reason (#63) ---------------------------------------------

  # ⚠⚠ **クライアントに判定を書き直させない。**`status` と `expires_at` だけ返すと、
  # `active` のまま期限が過ぎた行を画面が「有効」と出し、**ゲートと別の結論**になる。
  def test_response_carries_the_gate_decision
    token = issue
    get_status(token)
    body = json_response

    assert(body.key?('entitled'), 'entitled を返す')
    assert(body.key?('reason'), 'reason を返す')
    # ⚠ **真偽値であることを固定する。**下の検査は `refute` で書く（RuboCop の
    # Minitest/RefuteFalse）ので、**nil でも通ってしまう** —— 型はここで押さえる。
    assert_includes([true, false], body['entitled'], 'entitled は真偽値')
    # ストア未設定の環境なので `unverified` のまま＝通らない。
    assert_equal('unverified', body['status'])
    refute(body['entitled'])
    assert_equal('no_entitlement', body['reason'])
  end

  # ⚠⚠ **`RELAY_ENTITLEMENT_ENFORCE` を見ない。**見てしまうと、enforce を立てる前は
  # 画面が常に「有効」になる。知りたいのは「閉じたらどう扱われるか」。
  def test_the_decision_does_not_depend_on_the_enforce_flag
    token = issue
    with_env('RELAY_ENTITLEMENT_ENFORCE' => 'true') do
      get_status(token)

      refute(json_response['entitled'])
    end
    get_status(token)

    refute(json_response['entitled'])
  end

  # 期限の切れた `active` は「有効」と出さない（#63 の核心が口にも届く）。
  def test_active_past_its_expiry_is_reported_as_expired
    token = issue
    settings_database.apply_entitlement_verification(
      settings_database.find_entitlement_token(token)['entitlement_id'],
      Relay::Database::EntitlementVerification.new(
        store: 'apple', purchase_id: VALID[:purchase_id], product_id: VALID[:product_id],
        status: 'active', expires_at: '2020-01-01 00:00:00', environment: 'Production',
        signed_at: 1
      ),
    )
    get_status(token)

    assert_equal('active', json_response['status'])
    refute(json_response['entitled'])
    assert_equal('expired', json_response['reason'])
  end

  private

  def settings_database = app.settings.database

  def with_env(values)
    saved = values.keys.to_h {|key| [key, ENV.fetch(key, nil)]}
    values.each {|key, value| ENV[key] = value}
    yield
  ensure
    saved.each {|key, value| ENV[key] = value}
  end

  # `/metrics` から 1 系列の合計を読む。無ければ 0。
  def metrics_value(name)
    get('/metrics', {}, auth_headers)
    return last_response.body.lines
        .select {|line| line.start_with?(name)}
        .sum {|line| line.split.last.to_f}
  end
end
