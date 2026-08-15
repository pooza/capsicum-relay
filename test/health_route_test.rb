require_relative 'support/request_test_case'

# GET /health。#34 の request テスト土台の最小ケースであり、#37 で足した
# revision の出力もここで覆う（Revision 単体テストは値の解決だけを見ている）。
class HealthRouteTest < RequestTestCase
  def test_returns_ok
    get '/health'

    assert_equal(200, last_response.status)
    assert_equal('ok', json_response['status'])
  end

  def test_is_json
    get '/health'

    assert_match(%r{application/json}, last_response.headers['content-type'])
  end

  # 認証は要らない（監視から叩く）。
  def test_needs_no_secret
    get '/health'

    assert_equal(200, last_response.status)
  end

  # #37。Sentry の release と同じ文字列を出す。
  def test_reports_revision
    get '/health'

    assert_equal(Relay::Revision.current, json_response['revision'])
  end

  def test_reports_counts
    register_subscription

    get '/health'

    assert_equal(1, json_response['subscriptions'])
    assert_equal(0, json_response['announcement_subscriptions'])
    assert_equal(0, json_response['supporters'])
  end
end
