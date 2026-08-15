require_relative 'support/request_test_case'

# POST /supporters/tip / GET /supporters (#34)。投げ銭の記録 (capsicum#596 / #18)。
class SupporterRouteTest < RequestTestCase
  TIP = {account: 'alice@example.test', server: 'example.test'}.freeze

  def test_requires_secret
    post('/supporters/tip', TIP.to_json, {'CONTENT_TYPE' => 'application/json'})

    assert_equal(401, last_response.status)
  end

  def test_records_tip
    post_json('/supporters/tip', TIP)

    assert_equal(201, last_response.status)
    assert_equal('alice@example.test', json_response['account'])
    assert_equal(1, database.supporter_count)
  end

  def test_rejects_missing_fields
    post_json('/supporters/tip', {account: 'alice@example.test'})

    assert_equal(400, last_response.status)
    assert_match('server', json_response['error'])
  end

  # count はローカル既存レコードの汲み上げ（バックフィル）で複数件まとめる用。
  def test_accepts_count
    post_json('/supporters/tip', TIP.merge(count: 3))

    assert_equal(201, last_response.status)
  end

  def test_rejects_zero_count
    post_json('/supporters/tip', TIP.merge(count: 0))

    assert_equal(400, last_response.status)
  end

  def test_rejects_negative_count
    post_json('/supporters/tip', TIP.merge(count: -1))

    assert_equal(400, last_response.status)
  end

  # 文字列の "3" は通さない。Integer 判定を型ごと固定する。
  def test_rejects_non_integer_count
    post_json('/supporters/tip', TIP.merge(count: '3'))

    assert_equal(400, last_response.status)
  end

  # (account, server) 単位の upsert。2 回目で行は増えない。
  def test_tip_is_upserted_per_account_and_server
    post_json('/supporters/tip', TIP)
    post_json('/supporters/tip', TIP)

    assert_equal(1, database.supporter_count)
  end

  def test_fetches_supporter
    post_json('/supporters/tip', TIP)

    get('/supporters', TIP, auth_headers)

    assert_equal(200, last_response.status)
    assert_equal('alice@example.test', json_response['account'])
  end

  def test_fetch_requires_secret
    get('/supporters', TIP)

    assert_equal(401, last_response.status)
  end

  def test_fetch_rejects_missing_query
    get('/supporters', {account: 'alice@example.test'}, auth_headers)

    assert_equal(400, last_response.status)
  end

  def test_fetch_returns_404_for_unknown
    get('/supporters', TIP, auth_headers)

    assert_equal(404, last_response.status)
  end
end
