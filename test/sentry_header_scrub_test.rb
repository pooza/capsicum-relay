require_relative 'test_helper'
require 'relay/sentry_setup'

# Sentry へ送る前に capability を落とす。
#
# ⚠⚠ **例外が上がると Rack 統合がリクエストごと捕まえる。**capability を
# [Relay::SentrySetup::SENSITIVE_HEADERS] に入れ忘れると、**丸ごと外部へ出る。**
#
# ⚠ `X-Entitlement-Token` は**そのまま利用権として使える**（PR #81 の Codex P2）。
# `X-Relay-Secret` は `/register` と `/entitlements` の認証。
class SentryHeaderScrubTest < Minitest::Test
  # `event.request.headers` だけを持つ最小の代役。
  FakeRequest = Struct.new(:headers, :data)
  FakeEvent = Struct.new(:request)

  def scrubbed(headers)
    event = FakeEvent.new(FakeRequest.new(headers, 'body'))
    Relay::SentrySetup.scrub_event(event)
    return event.request.headers
  end

  # ⚠⚠ **これが落ちたら、利用権がそのまま Sentry へ出ている。**
  def test_capability_headers_are_removed
    left = scrubbed({
      'X-Relay-Secret' => 'secret',
      'X-Entitlement-Token' => 'capability',
      'Authorization' => 'vapid t=…',
      'Crypto-Key' => 'dh=…',
      'Encryption' => 'salt=…',
      'User-Agent' => 'keep-me',
    })

    assert_equal(['User-Agent'], left.keys)
  end

  # ⚠ 小文字で入っていても落とす（統合によって大小が揃わない）。
  def test_lowercase_names_are_removed_too
    left = scrubbed({'x-entitlement-token' => 'capability', 'accept' => 'json'})

    assert_equal(['accept'], left.keys)
  end

  # ⚠ body も落とす（購入 ID などが入りうる）。
  def test_the_body_is_dropped
    event = FakeEvent.new(FakeRequest.new({}, '{"purchase_id":"…"}'))
    Relay::SentrySetup.scrub_event(event)

    assert_nil(event.request.data)
  end

  # ⚠ request コンテキストを持たない event（worker 由来）はそのまま通す。
  def test_events_without_a_request_pass_through
    event = FakeEvent.new(nil)

    assert_same(event, Relay::SentrySetup.scrub_event(event))
  end
end
