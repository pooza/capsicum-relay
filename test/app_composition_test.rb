require_relative 'support/request_test_case'

# App が route クラスをどう束ねているか (#34)。
#
# ⚠ ここが守っているのは「**middleware として連ねる**ことで、route が一致した
# うえでの `halt 404` を次のアプリに流さない」という性質。`Rack::Cascade` で
# 束ねると status だけを見て次へ渡すため、`DELETE /register/:id` の 404 が
# 後続に食われて別の応答に化ける。
class AppCompositionTest < RequestTestCase
  def test_unknown_path_is_not_found
    get '/nope'

    assert_equal(404, last_response.status)
  end

  # route が意図して返す 404 は、その route の JSON がそのまま出る。
  def test_intentional_not_found_keeps_its_body
    delete('/register/9999', {}, auth_headers)

    assert_equal(404, last_response.status)
    assert_equal('Not found', json_response['error'])
  end

  def test_intentional_not_found_from_announcement_route_keeps_its_body
    delete('/announcement_subscriptions/9999', {}, auth_headers)

    assert_equal(404, last_response.status)
    assert_equal('Not found', json_response['error'])
  end

  # /supporters の 404 も同様（3 つの route クラスがそれぞれ 404 を返しうる）。
  def test_intentional_not_found_from_supporters_route_keeps_its_body
    get('/supporters', {account: 'a@b.test', server: 'b.test'}, auth_headers)

    assert_equal(404, last_response.status)
    assert_equal('Not found', json_response['error'])
  end

  # 401 も同じ理由で次へ流れてはいけない。
  def test_unauthorized_is_not_forwarded
    delete '/register/9999'

    assert_equal(401, last_response.status)
    assert_equal('Unauthorized', json_response['error'])
  end

  # 全 route クラスが同じ設定・同じ DB を見ている（BaseApp から継承）。
  def test_route_classes_share_one_database
    [
      Relay::Routes::AnnouncementSubscriptions,
      Relay::Routes::Health,
      Relay::Routes::Push,
      Relay::Routes::Register,
      Relay::Routes::Supporters,
    ].each do |klass|
      assert_same(database, klass.settings.database, klass.name)
    end
  end

  # 405 を返す HTTP メソッド違いも、束ね方によっては次へ流れる。
  def test_wrong_method_does_not_reach_another_route
    put('/register', {}.to_json, auth_headers)

    refute_equal(200, last_response.status)
    refute_equal(201, last_response.status)
  end
end
