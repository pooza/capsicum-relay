require_relative 'support/request_test_case'

# POST /push/:push_token (#34)。Mastodon / Misskey からの Web Push 受け口。
#
# ⚠ **この route だけ認証が無い。** 上流の SNS が叩くので共有シークレットを
# 持たせられず、push_token そのものが capability になっている。
#
# 実送信は fixture が apns / fcm / wns を持たないので 503 で止まる。ここで見るのは
# route の責務（未知トークンの扱い・dedup・未設定時の応答）だけで、配信結果の
# ハンドリングは各クライアントの unit テストの担当。
class PushRouteTest < RequestTestCase
  def setup
    super
    @parent = register_subscription
  end

  def push(token: @parent['push_token'], body: 'encrypted-body', headers: {})
    return post(
      "/push/#{token}",
      body,
      {'CONTENT_TYPE' => 'application/octet-stream'}.merge(headers),
    )
  end

  def test_needs_no_secret
    push

    refute_equal(401, last_response.status)
  end

  # ⚠ 404 ではなく **410**。Mastodon は 410 Gone で subscription を自動 destroy
  # するので、404 を返すと上流に古い subscription が残り続ける。
  def test_unknown_push_token_is_gone
    push(token: 'nope')

    assert_equal(410, last_response.status)
    assert_equal('Unknown push token', json_response['error'])
  end

  # クライアント未設定なら 503。ここが 500 に化けると上流が retry を始める。
  def test_returns_503_when_client_is_not_configured
    push

    assert_equal(503, last_response.status)
    assert_match('APNs', json_response['error'])
  end

  # 上流の孤児購読による重複 push を抑止 (capsicum#692 / #16)。
  # ⚠ **2 通目は上流に成功として返す。** 4xx / 5xx だと retry や subscription
  # destroy を誘発する。
  def test_duplicate_push_is_deduped_and_reported_as_success
    headers = {'HTTP_TOPIC' => 'topic-1'}
    push(headers: headers)
    push(headers: headers)

    assert_equal(200, last_response.status)
    assert_equal('deduped', json_response['status'])
  end

  def test_different_topic_is_not_deduped
    push(headers: {'HTTP_TOPIC' => 'topic-1'})
    push(headers: {'HTTP_TOPIC' => 'topic-2'})

    refute_equal('deduped', json_response['status'])
  end

  # ⚠ **Topic があるときは長さを見ない**（同一通知の再送は暗号文が変わるため）。
  # 長さ違いでも Topic が同じなら畳むのが設計どおり。
  def test_same_topic_is_deduped_even_when_length_differs
    headers = {'HTTP_TOPIC' => 'topic-1'}
    push(headers: headers, body: 'aaaa')
    push(headers: headers, body: 'bbbbbbbbbb')

    assert_equal('deduped', json_response['status'])
  end

  # Topic 無しでは Content-Length が判別材料になる。
  def test_same_length_without_topic_is_deduped
    push(body: 'aaaa')
    push(body: 'bbbb')

    assert_equal('deduped', json_response['status'])
  end

  def test_different_length_without_topic_is_not_deduped
    push(body: 'aaaa')
    push(body: 'bbbbbbbbbb')

    refute_equal('deduped', json_response['status'])
  end
end
