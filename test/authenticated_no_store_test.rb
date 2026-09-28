require_relative 'support/request_test_case'

# 認証が要る応答をキャッシュさせない（PR #81 の Codex P2）。
#
# 🔴 **`GET /entitlements` で実際に穴になっていた。**区別する値
# （`X-Entitlement-Token`）が**カスタムヘッダにしか無い**ので、⚠⚠ **キャッシュ鍵は
# 全員同じ** —— ブラウザ / CDN / 前段のプロキシが**最初の呼び出し元の token と
# 購入 ID を別人へ返しうる。**
#
# ⚠ **`authenticate!` に置いてある**（入口を 1 本にする）。route ごとに足すと、
# **認証付きの GET を増やしたときに付け忘れる。**
class AuthenticatedNoStoreTest < RequestTestCase
  # 認証が要る GET。⚠ **増えたらここにも足す**（この一覧が門の数と一致する）。
  AUTHENTICATED_GETS = [
    '/metrics',
    '/entitlements',
    '/supporters?account=a@b.test&server=b.test',
  ].freeze

  def test_authenticated_responses_are_not_cacheable
    AUTHENTICATED_GETS.each do |path|
      get(path, {}, auth_headers)

      assert_equal(
        'private, no-store', last_response.headers['Cache-Control'],
        "#{path} がキャッシュされうる"
      )
    end
  end

  # ⚠ 401 でも付ける（拒否そのものをキャッシュさせない）。
  def test_rejected_responses_are_not_cacheable_either
    get('/metrics', {}, {'HTTP_X_RELAY_SECRET' => 'wrong'})

    assert_equal(401, last_response.status)
    assert_equal('private, no-store', last_response.headers['Cache-Control'])
  end

  # ⚠⚠ **`/health` には付かない**（無認証・監視から叩く口で、秘密を返さない）。
  # ここが「認証が要る応答だけ」を意味することを固定する。
  def test_health_is_untouched
    get('/health')

    assert_equal(200, last_response.status)
    assert_nil(last_response.headers['Cache-Control'])
  end
end
