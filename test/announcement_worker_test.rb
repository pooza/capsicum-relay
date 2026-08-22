require_relative 'test_helper'
require 'json'
require 'logger'
require 'lib/relay/announcement_worker'
# 上限は WnsClient が持つ定数を参照する（テスト側に数値を写さない）。
require 'lib/relay/wns_client'
# 配送結果の counter (#44)。
require 'lib/relay/metrics'

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

    def initialize(result = {success: true})
      @pushes = []
      @result = result
    end

    # ⚠ **戻り値は deliver が見る** (#44)。以前は記録した配列を返していたが、
    # 現在は push クライアントの契約どおり結果 Hash を返す必要がある
    # （Hash でないものは outcome `no_result` として観測に出る）。
    def push(**kwargs)
      @pushes << kwargs
      return @result
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

  # --- windows 宛だけの payload 変形 (#36 Phase 2) ---

  def deliver_with_content(device_type, content: "<p>#{'あ' * 3000}</p>")
    return deliver(
      device_type,
      payload: {
        'notification_type' => 'announcement',
        'announcement_id' => '42',
        'announcement_content' => content,
      },
    )
  end

  def windows_payload(content: "<p>#{'あ' * 3000}</p>")
    deliver_with_content('windows', content: content)
    return @wns.pushes.first[:payload]
  end

  # ⚠ **本題その 1**: WNS raw の上限は 5000B。Windows は announcement_content を
  # 1 バイトも読まない（capsicum の TryBuildAnnouncementDisplay）ので、載せた
  # ままだと長文のお知らせが「表示に使わないデータのせいで」まるごと落ちる。
  def test_windows_payload_drops_html_content
    payload = windows_payload

    refute(payload.key?('announcement_content'))
    assert_operator(payload.to_json.bytesize, :<, Relay::WnsClient::RAW_PAYLOAD_LIMIT)
  end

  # ⚠ **本題その 2**: bg task はこの整形済み本文でトーストを組む。無いと
  # `bgtask.announcement_no_body` に落ちて何も表示されない。
  def test_windows_payload_carries_summarized_body
    payload = windows_payload(content: '<p>こんにちは <b>世界</b></p>')

    assert_equal('こんにちは 世界', payload['announcement_body'])
  end

  # プレビュー長で切る。切った印（…）が付くことまで見る — 付かないと
  # 「本文が短い」のか「切れている」のか端末側で区別できない。
  def test_windows_payload_body_is_truncated_with_ellipsis
    payload = windows_payload(content: "<p>#{'あ' * 100}</p>")

    assert_equal(81, payload['announcement_body'].length)
    assert(payload['announcement_body'].end_with?('…'))
  end

  # 全部が空になっても nil にしない（capsicum 側は空文字なら表示しない判断を
  # するので、キー自体が消えると「旧 relay」と区別できなくなる）。
  def test_windows_payload_body_is_string_even_when_content_is_empty
    payload = windows_payload(content: '')

    assert_equal('', payload['announcement_body'])
  end

  # 削るのは content だけ。宛先・Tag 用の id は残す。
  def test_windows_payload_keeps_display_fields
    payload = windows_payload

    assert_equal('42', payload['announcement_id'])
    assert_equal('alice@example', payload['account'])
  end

  # ⚠ 逆向きの固定 その 1。iOS / macOS / Android は content からフル HTML を
  # レンダリングする経路 (#477) を持っているので、削ると既存表示が壊れる。
  def test_apns_and_fcm_payloads_keep_html_content
    deliver_with_content('macos')
    deliver_with_content('android')

    assert(@apns.pushes.first[:payload].key?('announcement_content'))
    assert(@fcm.pushes.first[:payload].key?('announcement_content'))
  end

  # ⚠ 逆向きの固定 その 2（Codex P1 / PR #43）。**windows 以外の payload は
  # Phase 2 の前後で不変**でなければならない。announcement_body を全 device_type
  # に足すと、4KB 上限に近いお知らせが APNs / FCM で新たに上限超えになりうる。
  # degrade は暗号化キーしか落とさないので救えず、poll_server は dispatch 後に
  # mark_announcement_seen を打つので**再送もされない**（その 1 通が永久に消える）。
  def test_apns_and_fcm_payloads_do_not_gain_the_windows_preview
    deliver_with_content('macos')
    deliver_with_content('android')

    refute(@apns.pushes.first[:payload].key?('announcement_body'))
    refute(@fcm.pushes.first[:payload].key?('announcement_body'))
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

  # --- iOS / macOS 宛だけの dedup stamp (#45) ---

  def apns_payload(device_type: 'macos', announcement_id: '42')
    deliver(
      device_type,
      payload: {'notification_type' => 'announcement', 'announcement_id' => announcement_id},
    )
    return @apns.pushes.first[:payload]
  end

  # ⚠ **本題**。macOS 背面では willPresent が呼ばれず OS 既定の banner が出るが、
  # DeliveredPushCleaner は body を持たない通知を「解決不能＝削除対象外」にする。
  # このキーがあると復号せず `<account>|announcement:<id>` を返せるので、
  # WebSocket 経路 (capsicum#569) が登録した同じキーと一致して掃除される。
  def test_apns_payload_carries_the_dedup_stamp
    assert_equal('announcement:42', apns_payload['capsicum_notification_id'])
  end

  # iOS も同じ payload（同一 Bundle ID・同一 APNs Auth Key）。
  def test_ios_payload_carries_the_dedup_stamp
    assert_equal('announcement:42', apns_payload(device_type: 'ios')['capsicum_notification_id'])
  end

  # ⚠ **値の形は capsicum 側と噛み合う契約**。両 streaming がお知らせの通知 id を
  # `announcement:<id>` にしているので、prefix を変えるとキーが一致しなくなり、
  # 「残骸が消えない」に静かに戻る（例外にもテスト失敗にもならない）。
  def test_dedup_stamp_uses_the_announcement_prefix
    assert_equal(
      'announcement:xyz', apns_payload(announcement_id: 'xyz')['capsicum_notification_id']
    )
  end

  # id が無い（想定外の入力）ときは足さない。`announcement:` だけのキーは
  # capsicum 側の別のお知らせと衝突しうる。
  def test_dedup_stamp_is_omitted_without_an_id
    deliver('macos', payload: {'notification_type' => 'announcement'})

    refute(@apns.pushes.first[:payload].key?('capsicum_notification_id'))
  end

  # ⚠ 逆向きの固定。**android / windows には足さない。** キー 1 つで 50 バイト強
  # 増え、APNs / FCM は 4KB 上限に対して degrade も再送も効かない (#44)。android は
  # WebSocket 経路の dedup を持たず使い道が無い。windows は in-process 側が raw push
  # を食い止めるので二重表示自体が起きない。
  def test_other_device_types_do_not_gain_the_dedup_stamp
    deliver('android', payload: {'notification_type' => 'announcement', 'announcement_id' => '42'})
    deliver('windows', payload: {'notification_type' => 'announcement', 'announcement_id' => '42'})

    refute(@fcm.pushes.first[:payload].key?('capsicum_notification_id'))
    refute(@wns.pushes.first[:payload].key?('capsicum_notification_id'))
  end

  # 共通 payload そのものは増やさない（Windows 用の announcement_body と同じ扱いで、
  # 配送時の変形として足す）。
  def test_common_payload_has_no_dedup_stamp
    refute(build_payload('<p>x</p>').key?('capsicum_notification_id'))
  end

  # --- 配送の結末を観測に落とす (#44) ---
  #
  # reporter 単体の分岐は announcement_delivery_reporter_test が持つ。ここで見るのは
  # **worker から reporter まで実際に配線されているか**（#36 の from_settings と同じ
  # 理由 — 途中で落ちていても例外にならず、購読行はあるのに何も残らない形になる）。

  def metrics_worker(result: {success: true})
    @metrics = Relay::Metrics.new
    @apns = RecordingClient.new(result)
    return Relay::AnnouncementWorker.new(
      database: nil, logger: Logger.new(IO::NULL), apns: @apns, metrics: @metrics,
    )
  end

  def announcement_counter(outcome, device_type: 'macos')
    return @metrics.value(
      'relay_announcement_push_total', {device_type: device_type, outcome: outcome}
    )
  end

  def deliver_via(worker, device_type: 'macos')
    return worker.send(
      :deliver,
      sub: {'device_type' => device_type, 'token' => 'tok', 'account' => 'a@b'},
      payload: {}, alert: {}, server: 'mstdn.example', announcement_id: '170'
    )
  end

  def test_successful_delivery_is_counted
    worker = metrics_worker

    assert_equal('success', deliver_via(worker))
    assert_equal(1, announcement_counter('success'))
  end

  # ⚠ **この Issue の主題。** 以前はここで戻り値を捨てていたため、失敗しても
  # journald にも /metrics にも Sentry にも何も残らなかった（そのうえ poll_server は
  # dispatch の後で無条件に mark_announcement_seen を打つので再送もされない）。
  def test_failed_delivery_is_counted
    worker = metrics_worker(result: {success: false, status: 502, reason: 'Unavailable'})

    assert_equal('failed', deliver_via(worker))
    assert_equal(1, announcement_counter('failed'))
  end

  # 長文のお知らせは degrade で救えず 1 通ドロップする（#44 の 2026-08-16 コメント）。
  # 再送はこの Issue の範囲外なので、**落ちたことが数字で見える**ところまでを見る。
  def test_oversized_delivery_is_counted
    worker = metrics_worker(result: {success: false, oversized: true, status: 413})

    assert_equal('oversized', deliver_via(worker))
    assert_equal(1, announcement_counter('oversized'))
  end

  def test_client_exception_is_counted
    worker = metrics_worker
    @apns.define_singleton_method(:push) {|**_kwargs| raise(IOError, 'broken pipe')}

    assert_equal('exception', deliver_via(worker))
    assert_equal(1, announcement_counter('exception'))
  end

  # クライアント未設定は「設定漏れ」、未知の device_type は「配送が register に
  # 追いついていない」印。どちらも従来は黙って捨てていた。
  def test_missing_client_is_recorded_as_unconfigured
    worker = Relay::AnnouncementWorker.new(
      database: nil, logger: Logger.new(IO::NULL), metrics: (@metrics = Relay::Metrics.new),
    )

    assert_equal('unconfigured', deliver_via(worker))
    assert_equal(1, announcement_counter('unconfigured'))
  end

  def test_unknown_device_type_is_recorded_as_unconfigured
    worker = metrics_worker

    assert_equal('unconfigured', deliver_via(worker, device_type: 'symbian'))
    assert_equal(1, announcement_counter('unconfigured', device_type: 'symbian'))
    assert_empty(@apns.pushes)
  end

  # `/metrics` の counter は App と同じインスタンスを共有する（同一プロセスの
  # 別スレッド）。ここを渡し忘れると counter が永久に 0 のままになる。
  def test_from_settings_wires_metrics
    metrics = Relay::Metrics.new
    settings = Struct.new(:apns, :metrics).new(@apns, metrics)
    worker = Relay::AnnouncementWorker.from_settings(
      settings, database: nil, logger: Logger.new(IO::NULL), interval: 0
    )
    worker.send(
      :deliver,
      sub: {'device_type' => 'macos', 'token' => 'tok', 'account' => 'a@b'},
      payload: {}, alert: {}
    )

    assert_equal(
      1, metrics.value('relay_announcement_push_total', {device_type: 'macos', outcome: 'success'})
    )
  end

  # --- payload の組み立て (#36 Phase 2 / capsicum#978) ---

  def build_payload(content)
    return @worker.send(
      :build_payload,
      'example.test',
      {'id' => '42', 'content' => content, 'published_at' => '2026-08-16T00:00:00Z'},
    )
  end

  # HTML のままの content を載せる（capsicum がタップ後にフルレンダリング
  # する経路が使っている）。落とすと既存挙動が壊れる。
  def test_payload_keeps_raw_html_content
    payload = build_payload('<p>こんにちは</p>')

    assert_equal('<p>こんにちは</p>', payload['announcement_content'])
  end

  # ⚠ **共通 payload は Phase 2 で 1 バイトも増やさない**（Codex P1 / PR #43）。
  # Windows 用の announcement_body は wns_payload が配送時に足す。
  def test_payload_has_no_windows_preview
    refute(build_payload('<p>こんにちは</p>').key?('announcement_body'))
  end

  # ⚠ title は載せない。サーバーから来ないので capsicum 側の統一ラベル表で
  # 解決する（載せると「どちらが正か」が 2 箇所に散る）。
  def test_payload_has_no_title
    refute(build_payload('<p>x</p>').key?('announcement_title'))
  end
end
