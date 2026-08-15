require_relative 'test_helper'
require 'json'
require 'logger'
require 'lib/relay/announcement_worker'
# 上限は WnsClient が持つ定数を参照する（テスト側に数値を写さない）。
require 'lib/relay/wns_client'

# #36: お知らせ通知の配送先を macOS (Phase 1) / Windows (Phase 2) へ広げる。
#
# `deliver` の分岐は通常の push 経路（`Relay::PushHelpers#push_client_for`）と
# **同じ形でなければならない**。register は 4 種すべてを受け付け、
# `announcement_subscriptions_for_server` も device_type / token を返すので、
# ここが揃っていないぶんだけ「登録できるのに届かない」端末が生まれる。
#
# Phase 2 で 4 種すべてが揃った（capsicum#978 の bg task が無暗号化エンベロープを
# 解釈できるようになったため）。残る非対称は **windows だけ payload が違う**点で、
# 下の wns_payload 系のテストがそれを固定する。
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
    @wns = RecordingClient.new
    @worker = Relay::AnnouncementWorker.new(
      database: nil,
      logger: Logger.new(IO::NULL),
      apns: @apns,
      fcm: @fcm,
      wns: @wns,
    )
  end

  def deliver(device_type, token: 'tok', payload: {'notification_type' => 'announcement'})
    @worker.send(
      :deliver,
      sub: {'device_type' => device_type, 'token' => token, 'account' => 'alice@example'},
      payload: payload,
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

  # Phase 2 の本体 (capsicum#978)。bg task が無暗号化エンベロープを解釈できる
  # ようになったので、ここを足して初めて Windows へ配送される。
  def test_windows_goes_to_wns
    deliver('windows')

    assert_equal(1, @wns.pushes.size)
    assert_empty(@apns.pushes)
    assert_empty(@fcm.pushes)
  end

  # WNS raw に alert 相当の機構は無い。トーストは capsicum が payload から
  # 組むので、alert を渡してしまうと「使われない大きな引数」になる。
  def test_windows_is_pushed_without_alert
    deliver('windows')

    refute(@wns.pushes.first.key?(:alert))
  end

  def test_unknown_device_type_is_ignored
    deliver('symbian')

    assert_empty(@apns.pushes)
    assert_empty(@fcm.pushes)
    assert_empty(@wns.pushes)
  end

  # --- windows 宛だけ payload を削る (#36 Phase 2) ---

  def deliver_with_content(device_type)
    return deliver(
      device_type,
      payload: {
        'notification_type' => 'announcement',
        'announcement_id' => '42',
        'announcement_content' => "<p>#{'あ' * 3000}</p>",
        'announcement_body' => 'あああ',
      },
    )
  end

  # ⚠ **本題**: WNS raw の上限は 5000B。Windows は announcement_content を
  # 1 バイトも読まない（capsicum の TryBuildAnnouncementDisplay）ので、載せた
  # ままだと長文のお知らせが「表示に使わないデータのせいで」まるごと落ちる。
  def test_windows_payload_drops_html_content
    deliver_with_content('windows')

    payload = @wns.pushes.first[:payload]
    refute(payload.key?('announcement_content'))
    assert_operator(payload.to_json.bytesize, :<, Relay::WnsClient::RAW_PAYLOAD_LIMIT)
  end

  # 削るのは content だけ。表示に要る本文・宛先・Tag 用の id は残す。
  def test_windows_payload_keeps_display_fields
    deliver_with_content('windows')

    payload = @wns.pushes.first[:payload]
    assert_equal('あああ', payload['announcement_body'])
    assert_equal('42', payload['announcement_id'])
    assert_equal('alice@example', payload['account'])
  end

  # ⚠ 逆向きの固定。iOS / macOS / Android は content からフル HTML を
  # レンダリングする経路 (#477) を持っているので、削ると既存表示が壊れる。
  def test_apns_and_fcm_payloads_keep_html_content
    deliver_with_content('macos')
    deliver_with_content('android')

    assert(@apns.pushes.first[:payload].key?('announcement_content'))
    assert(@fcm.pushes.first[:payload].key?('announcement_content'))
  end

  # account は payload へ混ぜて送る（capsicum 側が宛先アカウントを解決する）。
  def test_account_is_merged_into_payload
    deliver('macos')

    assert_equal('alice@example', @apns.pushes.first[:payload]['account'])
    assert_equal('announcement', @apns.pushes.first[:payload]['notification_type'])
  end

  # クライアント未設定（設定漏れ・起動順）でも落とさない。
  # ⚠ windows も含める。base_app が `wns:` を渡し忘れると、購読行はあるのに
  # 1 通も届かない形になるが、例外にはならず静かに無効化される。
  def test_missing_client_is_survived
    worker = Relay::AnnouncementWorker.new(
      database: nil, logger: Logger.new(IO::NULL), apns: nil, fcm: nil, wns: nil,
    )

    ['macos', 'windows'].each do |device_type|
      worker.send(
        :deliver,
        sub: {'device_type' => device_type, 'token' => 'tok', 'account' => 'a@b'},
        payload: {}, alert: {}
      )
    end
  end

  # --- base_app からの配線 (#36 Phase 2) ---

  # `deliver` に device_type を足しても、settings から拾い忘れれば
  # 「購読行はあるのに 1 通も届かない」形になる。例外にならないので、ここで
  # 見ていないと**テストにもログにも出ない**（Phase 2 の実装中に実測した）。
  def test_from_settings_wires_every_push_client
    settings = Struct.new(:apns, :fcm, :wns).new(@apns, @fcm, @wns)
    worker = Relay::AnnouncementWorker.from_settings(
      settings, database: nil, logger: Logger.new(IO::NULL), interval: 0
    )

    ['ios', 'macos', 'android', 'windows'].each do |device_type|
      worker.send(
        :deliver,
        sub: {'device_type' => device_type, 'token' => 'tok', 'account' => 'a@b'},
        payload: {}, alert: {}
      )
    end

    assert_equal(2, @apns.pushes.size, 'ios + macos')
    assert_equal(1, @fcm.pushes.size, 'android')
    assert_equal(1, @wns.pushes.size, 'windows')
  end

  # 鍵が config に無いクライアントは base_app が `set` しないので、settings は
  # そのメソッドに応答しない。落とさず nil のまま組み立てる。
  def test_from_settings_survives_unconfigured_clients
    worker = Relay::AnnouncementWorker.from_settings(
      Struct.new(:nothing).new(nil),
      database: nil, logger: Logger.new(IO::NULL), interval: 0,
    )

    worker.send(
      :deliver,
      sub: {'device_type' => 'windows', 'token' => 'tok', 'account' => 'a@b'},
      payload: {}, alert: {}
    )

    assert_empty(@wns.pushes)
  end

  # --- payload の組み立て (#36 Phase 2 / capsicum#978) ---

  def build_payload(content)
    return @worker.send(
      :build_payload,
      'example.test',
      {'id' => '42', 'content' => content, 'published_at' => '2026-08-16T00:00:00Z'},
    )
  end

  # Windows の bg task はこの整形済み本文でトーストを組む。HTML のままの
  # `announcement_content` しか無いと、C++/WinRT 側に HTML 剥がしを 3 つ目の
  # 実装として書くことになる。
  def test_payload_carries_summarized_body
    payload = build_payload('<p>こんにちは <b>世界</b></p>')

    assert_equal('こんにちは 世界', payload['announcement_body'])
  end

  # HTML のままの content も従来どおり残す（capsicum 側がタップ後に
  # フルレンダリングする経路が使っている）。落とすと既存挙動が壊れる。
  def test_payload_keeps_raw_html_content
    payload = build_payload('<p>こんにちは</p>')

    assert_equal('<p>こんにちは</p>', payload['announcement_content'])
  end

  # プレビュー長で切る。切った印（…）が付くことまで見る — 付かないと
  # 「本文が短い」のか「切れている」のか端末側で区別できない。
  def test_payload_body_is_truncated_with_ellipsis
    payload = build_payload("<p>#{'あ' * 100}</p>")

    assert_equal(81, payload['announcement_body'].length)
    assert(payload['announcement_body'].end_with?('…'))
  end

  # 全部が空になっても nil にしない（capsicum 側は空文字なら表示しない判断を
  # するので、キー自体が消えると「旧 relay」と区別できなくなる）。
  def test_payload_body_is_string_even_when_content_is_empty
    payload = build_payload('')

    assert_equal('', payload['announcement_body'])
  end

  # ⚠ title は載せない。サーバーから来ないので capsicum 側の統一ラベル表で
  # 解決する（載せると「どちらが正か」が 2 箇所に散る）。
  def test_payload_has_no_title
    refute(build_payload('<p>x</p>').key?('announcement_title'))
  end
end
