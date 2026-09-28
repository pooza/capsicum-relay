require_relative 'support/request_test_case'

# GET /entitlements/:token（#80・capsicum#1123 の前提）。
#
# ⚠⚠ **`POST` を状態確認に使い回さないための口。**あちらは upsert なので冪等では
# あるが、呼ぶたびに `relay_entitlement_token_total` が増え `entitlement.issued` が
# 出る —— **「発行の回数」を数えている counter が「画面を開いた回数」に汚染され、
# ゲートを閉じてよいかの判断材料が濁る。**
#
# ⚠ ここで固定したいのは 3 つ。
#
# 1. 手元の token から**いまの状態**が読める
# 2. ⚠⚠ **metrics もログも増えない**（この口の存在理由そのもの）
# 3. ⚠ **知らない token は 404**（「失効」と混ぜない —— クライアントから見て
#    「端末の保存が壊れた」と「解約された」は別の状況で、案内が違う）
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

  def get_json(path, secret: SECRET)
    return get(path, {}, auth_headers(secret: secret))
  end

  def test_requires_secret
    token = issue
    get("/entitlements/#{token}", {}, {'CONTENT_TYPE' => 'application/json'})

    assert_equal(401, last_response.status)
  end

  def test_reads_the_current_state
    token = issue
    get_json("/entitlements/#{token}")

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
    get_json("/entitlements/#{token}")

    assert_equal(issued.keys.sort, json_response.keys.sort)
  end

  # ⚠⚠ **この口の存在理由。**増えたら `POST` を使い回すのと変わらない。
  def test_does_not_count_as_an_issuance
    token = issue
    before = metrics_value('relay_entitlement_token_total')
    3.times {get_json("/entitlements/#{token}")}

    assert_equal(before, metrics_value('relay_entitlement_token_total'))
  end

  # ⚠ 「知らない」と「失効」を混ぜない。
  def test_unknown_token_is_not_found
    get_json('/entitlements/there-is-no-such-token')

    assert_equal(404, last_response.status)
  end

  private

  # `/metrics` から 1 系列の合計を読む。無ければ 0。
  def metrics_value(name)
    get('/metrics', {}, auth_headers)
    return last_response.body.lines
        .select {|line| line.start_with?(name)}
        .sum {|line| line.split.last.to_f}
  end
end
