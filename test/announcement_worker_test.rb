require_relative 'test_helper'
require 'logger'
require 'lib/relay/announcement_worker'

# #36 Phase 1: お知らせ通知の配送先を macOS へ広げる。
#
# `deliver` の分岐は通常の push 経路（`Relay::PushHelpers#push_client_for`）と
# **同じ形でなければならない**。register は 4 種すべてを受け付け、
# `announcement_subscriptions_for_server` も device_type / token を返すので、
# ここが揃っていないぶんだけ「登録できるのに届かない」端末が生まれる。
#
# ⚠ **windows をまだ足していないのは意図的**（Phase 2）。relay 側だけ足すと
# capsicum の bg task が無暗号化ペイロードを捨てるので、**送っても黙って
# 消える**。それを「未実装」でなく「壊れている」に見せないよう、ここで
# 「送らない」ことを固定する。
class AnnouncementWorkerTest < Minitest::Test
  # push された引数を記録するだけのクライアント。
  class RecordingClient
    attr_reader :pushes

    def initialize
      @pushes = []
    end

    # 返り値は deliver 側で使われない。真偽だけを返すと
    # Naming/PredicateMethod に引っかかるので記録した配列をそのまま返す。
    def push(**kwargs)
      return @pushes << kwargs
    end
  end

  def setup
    @apns = RecordingClient.new
    @fcm = RecordingClient.new
    @worker = Relay::AnnouncementWorker.new(
      database: nil,
      logger: Logger.new(IO::NULL),
      apns: @apns,
      fcm: @fcm,
    )
  end

  def deliver(device_type, token: 'tok')
    @worker.send(
      :deliver,
      sub: {'device_type' => device_type, 'token' => token, 'account' => 'alice@example'},
      payload: {'notification_type' => 'announcement'},
      alert: {title: 'お知らせ', body: '本文'},
    )
  end

  def test_ios_goes_to_apns
    deliver('ios')

    assert_equal(1, @apns.pushes.size)
    assert_empty(@fcm.pushes)
  end

  # Phase 1 の本体。iOS と同一 APNs クライアントで送れる (capsicum#468)。
  def test_macos_goes_to_apns
    deliver('macos')

    assert_equal(1, @apns.pushes.size)
    assert_empty(@fcm.pushes)
  end

  # macOS の NSE は `aps.alert` をそのまま出すので、alert を落とすと無音になる。
  def test_macos_carries_alert
    deliver('macos')

    assert_equal({title: 'お知らせ', body: '本文'}, @apns.pushes.first[:alert])
  end

  def test_android_goes_to_fcm
    deliver('android')

    assert_equal(1, @fcm.pushes.size)
    assert_empty(@apns.pushes)
  end

  # ⚠ Phase 2 待ち。capsicum#978 が入るまでは送らないのが正しい。
  def test_windows_is_not_delivered_yet
    deliver('windows')

    assert_empty(@apns.pushes)
    assert_empty(@fcm.pushes)
  end

  def test_unknown_device_type_is_ignored
    deliver('symbian')

    assert_empty(@apns.pushes)
    assert_empty(@fcm.pushes)
  end

  # account は payload へ混ぜて送る（capsicum 側が宛先アカウントを解決する）。
  def test_account_is_merged_into_payload
    deliver('macos')

    assert_equal('alice@example', @apns.pushes.first[:payload]['account'])
    assert_equal('announcement', @apns.pushes.first[:payload]['notification_type'])
  end

  # クライアント未設定（設定漏れ・起動順）でも落とさない。
  def test_missing_client_is_survived
    worker = Relay::AnnouncementWorker.new(
      database: nil, logger: Logger.new(IO::NULL), apns: nil, fcm: nil,
    )

    worker.send(
      :deliver,
      sub: {'device_type' => 'macos', 'token' => 'tok', 'account' => 'a@b'},
      payload: {}, alert: {}
    )
  end
end
