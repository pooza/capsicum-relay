require_relative 'support/request_test_case'

# POST / DELETE / GET /announcement_subscriptions (#34)。
#
# ⚠ 親 subscription が要る（FK）。事前に存在確認して 404 を返すのは、FK 制約の
# 失敗を capsicum 側でハンドリングさせないための入口チェック。
class AnnouncementSubscriptionRouteTest < RequestTestCase
  def setup
    super
    @parent = register_subscription
    @body = {
      push_token: @parent['push_token'],
      server: 'example.test',
      account: 'alice@example.test',
    }
  end

  def test_requires_secret
    post('/announcement_subscriptions', @body.to_json, {'CONTENT_TYPE' => 'application/json'})

    assert_equal(401, last_response.status)
  end

  def test_registers
    post_json('/announcement_subscriptions', @body)

    assert_equal(201, last_response.status)
    assert_equal('alice@example.test', json_response['account'])
    assert_equal(1, database.announcement_subscription_count)
  end

  def test_rejects_missing_fields
    post_json('/announcement_subscriptions', @body.except(:account))

    assert_equal(400, last_response.status)
    assert_match('account', json_response['error'])
  end

  # 親が居ない push_token。FK 失敗（500）ではなく 404 で返す。
  def test_returns_404_for_unknown_push_token
    post_json('/announcement_subscriptions', @body.merge(push_token: 'nope'))

    assert_equal(404, last_response.status)
    assert_equal('Unknown push token', json_response['error'])
  end

  def test_unregisters
    post_json('/announcement_subscriptions', @body)
    id = json_response['id']

    delete("/announcement_subscriptions/#{id}", {}, auth_headers)

    assert_equal(200, last_response.status)
    assert_equal(0, database.announcement_subscription_count)
  end

  def test_unregister_requires_secret
    post_json('/announcement_subscriptions', @body)

    delete("/announcement_subscriptions/#{json_response['id']}")

    assert_equal(401, last_response.status)
    assert_equal(1, database.announcement_subscription_count)
  end

  # ⚠ capsicum#979 で「404 を error として観測してしまう」と分かった経路。
  # relay 側は 404 のままでよく、冪等化は client 側の解釈で行う。
  def test_unregister_returns_404_for_unknown_id
    delete('/announcement_subscriptions/9999', {}, auth_headers)

    assert_equal(404, last_response.status)
  end

  # 状態確認用の一覧。capsicum が「relay 側にまだ購読が生きているか」を見る。
  def test_lists_by_push_token
    post_json('/announcement_subscriptions', @body)

    get("/announcement_subscriptions/#{@parent['push_token']}", {}, auth_headers)

    assert_equal(200, last_response.status)
    assert_equal(1, json_response['subscriptions'].size)
    assert_equal('alice@example.test', json_response['subscriptions'].first['account'])
  end

  def test_lists_empty_for_unknown_push_token
    get('/announcement_subscriptions/nope', {}, auth_headers)

    assert_equal(200, last_response.status)
    assert_empty(json_response['subscriptions'])
  end

  def test_list_requires_secret
    get("/announcement_subscriptions/#{@parent['push_token']}")

    assert_equal(401, last_response.status)
  end
end
