require_relative 'support/request_test_case'

# `/push` が上流へ返す HTTP ステータス (#66)。
#
# ⚠⚠ **ステータスの選び方は「上流が購読を消すか」で決まる。**
#
# | | 購読を消す条件 |
# | --- | --- |
# | Mastodon (`Web::PushNotificationWorker#send`) | `408` / `429` **以外の 4xx すべて** |
# | Misskey (`PushNotificationService`) | **`410` だけ** |
#
# → ⚠ **意図して消したいときだけ 4xx（410）を返す。**それ以外で 4xx を返すと、
# 健全な購読が黙って消える。#66 は 413 でこれを踏んでいた（想定と正反対）。
class PushOutcomeStatusTest < RequestTestCase
  # `push(device_token:, payload:)` だけを持つ差し替え用クライアント。
  class FakeClient
    def initialize(result) = @result = result
    def push(device_token:, payload:) = @result
  end

  def setup
    super
    @parent = register_subscription
  end

  # ⚠ App は全ケースで共有なので、**必ず戻す**（戻さないと後続が偽の
  # クライアントを掴んだまま走る）。
  def with_apns(result)
    had = Relay::BaseApp.settings.respond_to?(:apns)
    previous = had ? Relay::BaseApp.settings.apns : nil
    Relay::BaseApp.set(:apns, FakeClient.new(result))
    yield
  ensure
    Relay::BaseApp.set(:apns, previous) if had
    Relay::BaseApp.settings.set(:apns, nil) unless had
  end

  def push(token: @parent['push_token'])
    return post("/push/#{token}", 'body', {'CONTENT_TYPE' => 'application/octet-stream'})
  end

  def test_delivered_answers_ok
    with_apns({success: true}) {push}

    assert_equal(200, last_response.status)
    assert_equal('delivered', json_response['status'])
  end

  # ⚠⚠ **これが #66 の本体。**413 だと Mastodon が購読を destroy する。
  def test_oversized_answers_ok
    with_apns({success: false, oversized: true, status: 413, reason: 'PayloadTooLarge'}) do
      push
    end

    assert_equal(200, last_response.status)
    assert_equal('oversized', json_response['status'])
  end

  # ⚠ **クラスとしての歯止め。**「健全な購読を残したい」結末で 4xx を返してはいけない。
  def test_oversized_never_answers_4xx
    with_apns({success: false, oversized: true, status: 413}) {push}

    refute(
      (400..499).cover?(last_response.status),
      '4xx を返すと Mastodon が購読を destroy する（408 / 429 以外）',
    )
  end

  # ⚠ 購読は残る（unregister しない）。
  def test_oversized_keeps_the_subscription
    with_apns({success: false, oversized: true, status: 413}) {push}

    refute_nil(database.find_by_push_token(@parent['push_token']))
  end

  # ⚠ 410 は**意図して**消すとき。device token が無効になった場合。
  def test_gone_answers_gone_and_removes_the_row
    with_apns({success: false, permanent: true, reason: 'Unregistered'}) {push}

    assert_equal(410, last_response.status)
    assert_nil(
      database.find_by_push_token(@parent['push_token']),
      'relay 側の行も掃除する',
    )
  end

  # ⚠ 一過性の失敗は **5xx**。Mastodon は raise して retry する（消さない）。
  def test_failed_answers_server_error_so_upstream_retries
    with_apns({success: false, status: '500', reason: 'InternalServerError'}) {push}

    assert_equal(502, last_response.status)
    refute(
      (400..499).cover?(last_response.status),
      '4xx にすると retry されずに購読が消える',
    )
    refute_nil(database.find_by_push_token(@parent['push_token']))
  end

  # WNS の端末オフライン。⚠ 正常系なので 200（#24）。
  def test_wns_dropped_answers_ok
    with_apns({success: true, wns_status: 'dropped'}) {push}

    assert_equal(200, last_response.status)
  end
end
