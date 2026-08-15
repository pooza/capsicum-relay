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
    post_json('/register', VALID.reject {|k, _| k == :server})

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
end
