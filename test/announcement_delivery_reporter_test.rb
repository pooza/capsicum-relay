require_relative 'test_helper'
require 'lib/relay/announcement_delivery_reporter'
require 'lib/relay/metrics'
require 'lib/relay/push_helpers'

# #44: お知らせ配信が push の結末を見ていない。
#
# ここで固定するのは **outcome の名前と分岐の順序**、そして**どの結末が観測に
# 出るか**の 2 点。実装本体は「失敗しても seen を打つ」現状（C 案）をそのまま
# 残すので、テストも再送は見ない — 失敗が journald / counter に**残ること**が
# この Issue の完了条件。
class AnnouncementDeliveryReporterTest < Minitest::Test
  # logger に渡された Hash をそのまま溜める。StructuredLog::FORMATTER が
  # 1 行 1 JSON に落とす前の中身を見る（フォーマッタ自体は #2 のテスト側で固定済み）。
  class RecordingLogger
    attr_reader :records

    def initialize
      @records = []
    end

    [:info, :warn, :error].each do |level|
      define_method(level) do |payload|
        return @records << {level: level, payload: payload}
      end
    end
  end

  # どちらの unregister が呼ばれたかを見る差し替え。**2 つとも生やしておく**
  # — 親 (subscriptions) を消さないことがこのクラスの契約なので、呼べない
  # ダブルにしてしまうと「呼ばない」を確かめたことにならない。
  class RecordingDatabase
    attr_reader :unregistered, :unregistered_parents

    def initialize
      @unregistered = []
      @unregistered_parents = []
    end

    def unregister_announcement_subscription(id)
      return @unregistered << id
    end

    def unregister(id)
      return @unregistered_parents << id
    end
  end

  SUB = {
    'device_type' => 'ios', 'token' => 'devicetoken0123456789',
    'account' => 'alice@example', 'announcement_subscription_id' => 7
  }.freeze

  def setup
    @logger = RecordingLogger.new
    @metrics = Relay::Metrics.new
    @database = RecordingDatabase.new
    @reporter = Relay::AnnouncementDeliveryReporter.new(
      logger: @logger, metrics: @metrics, database: @database,
    )
  end

  def record(result, sub: SUB)
    return @reporter.record(
      sub: sub, server: 'mstdn.example', announcement_id: '170', result: result,
    )
  end

  def last
    return @logger.records.last
  end

  def counter(outcome, device_type: 'ios')
    return @metrics.value(
      'relay_announcement_push_total', {device_type: device_type, outcome: outcome}
    )
  end

  # --- outcome の分類（通常 push 経路と同じ順序・同じ名前） ---

  def test_success_is_recorded
    assert_equal('success', record({success: true}))
    assert_equal(1, counter('success'))
  end

  def test_failure_is_recorded_as_failed
    assert_equal('failed', record({success: false, status: 500, reason: 'InternalServerError'}))
    assert_equal(1, counter('failed'))
  end

  # 4KB 超過。degrade が空振りして 1 通ドロップした形（#44 の 2026-08-16 コメント）。
  def test_oversized_is_recorded
    assert_equal('oversized', record({success: false, oversized: true, status: 413}))
    assert_equal(1, counter('oversized'))
  end

  def test_permanent_failure_is_recorded_as_gone
    assert_equal('gone', record({success: false, permanent: true, reason: 'Unregistered'}))
    assert_equal(1, counter('gone'))
  end

  # ⚠ **oversized が permanent より先**。順序を入れ替えると、両方立った結果が
  # gone と呼ばれて**購読を消してしまう**（PushHelpers#handle_push_result と同じ順序）。
  def test_oversized_wins_over_permanent
    assert_equal('gone', record({success: false, permanent: true}))
    assert_equal('oversized', record({success: false, permanent: true, oversized: true}))
  end

  # WNS は 200 でも X-WNS-NotificationStatus で実質不達を返す (#474 レビュー)。
  def test_wns_status_is_recorded_when_not_received
    outcome = record(
      {success: true, wns_status: 'channelthrottled'},
      sub: SUB.merge('device_type' => 'windows'),
    )

    assert_equal('wns_channelthrottled', outcome)
    assert_equal(1, counter('wns_channelthrottled', device_type: 'windows'))
  end

  def test_degraded_is_recorded
    assert_equal('degraded', record({success: true, degraded: true, original_size: 5000}))
  end

  # クライアントが Hash を返さなかった（差し替え漏れ・想定外の戻り値）。黙って
  # 成功扱いにしない。
  def test_non_hash_result_is_recorded_as_no_result
    assert_equal('no_result', record(nil))
    assert_equal(1, counter('no_result'))
  end

  # --- ログレベル（正常系を warn に上げない） ---

  def test_success_is_logged_at_info
    record({success: true})

    assert_equal(:info, last[:level])
  end

  def test_failure_is_logged_at_error
    record({success: false, status: 502})

    assert_equal(:error, last[:level])
  end

  # ⚠ `dropped` は「端末がオフライン / スリープ」で raw notification が queue
  # されないだけの**正常系**。5.5 週で 4476 件たまった実績があり (#24)、warn に
  # 上げると本当の異常が埋もれる。判定は PushHelpers の定数を参照している。
  def test_benign_wns_status_stays_info
    record({success: true, wns_status: 'dropped'}, sub: SUB.merge('device_type' => 'windows'))

    assert_equal(:info, last[:level])
    assert_includes(Relay::PushHelpers::WNS_BENIGN_STATUSES, 'dropped')
  end

  # --- ログの中身（切り分けに要る軸） ---

  def test_log_carries_the_triage_fields
    record({success: false, status: 500, reason: 'boom'})
    payload = last[:payload]

    assert_equal('announcement.push.result', payload[:event])
    assert_equal('failed', payload[:outcome])
    assert_equal('ios', payload[:device_type])
    assert_equal('mstdn.example', payload[:server])
    assert_equal('170', payload[:announcement_id])
    assert_equal('boom', payload[:reason])
  end

  # 人間向けの 1 行を捨てない（journald の grep 手順。StructuredLog 参照）。
  def test_log_keeps_human_readable_message
    record({success: true})

    assert_match(/Announcement pushed to ios: alice@example/, last[:payload][:msg])
  end

  # --- 端末が無効化されたときの掃除 ---

  def test_gone_unregisters_the_announcement_subscription
    record({success: false, permanent: true, reason: 'BadDeviceToken'})

    assert_equal([7], @database.unregistered)
  end

  # ⚠ **親 subscription は消さない。** 通常 push が同じ端末で 404 / 410 を踏めば
  # handle_push_gone が Database#unregister を呼び、お知らせ購読も CASCADE で
  # 消える。お知らせ配信だけを根拠に端末ごと登録解除しない。
  def test_gone_does_not_touch_the_parent_subscription
    record({success: false, permanent: true})

    assert_empty(@database.unregistered_parents)
  end

  def test_success_does_not_unregister
    record({success: true})

    assert_empty(@database.unregistered)
  end

  # DB を持たない組み立て（テスト・起動順）でも落とさない。
  def test_gone_survives_without_database
    reporter = Relay::AnnouncementDeliveryReporter.new(logger: @logger, metrics: @metrics)

    assert_equal('gone', reporter.record(
      sub: SUB, server: 'mstdn.example', announcement_id: '1',
      result: {success: false, permanent: true}
    ))
  end

  # --- fan-out（「そもそも購読が無い」を journald だけで見分ける） ---

  # ⚠ **0 件でも 1 行出す。** #44 の 2026-08-18 のコメントで実際に切り分けが
  # 詰まった軸がこれ（macOS の購読が 1 行も無く、relay は送りようが無かった）。
  def test_dispatch_is_logged_even_with_no_subscriptions
    @reporter.record_dispatch(server: 'mstdn.example', announcement_id: '170', subs: [])
    payload = last[:payload]

    assert_equal('announcement.dispatch', payload[:event])
    assert_equal(0, payload[:subscriptions])
    assert_empty(payload[:device_types])
  end

  def test_dispatch_breaks_down_device_types
    subs = [{'device_type' => 'ios'}, {'device_type' => 'ios'}, {'device_type' => 'windows'}]
    @reporter.record_dispatch(server: 'mstdn.example', announcement_id: '170', subs: subs)

    assert_equal({'ios' => 2, 'windows' => 1}, last[:payload][:device_types])
  end

  # --- 送れなかった（クライアント未設定 / 未知の device_type） ---

  def test_unconfigured_is_recorded_with_reason
    outcome = @reporter.record_unconfigured(
      sub: SUB, server: 'mstdn.example', announcement_id: '170', reason: 'client_unset',
    )

    assert_equal('unconfigured', outcome)
    assert_equal(:warn, last[:level])
    assert_equal('client_unset', last[:payload][:reason])
    assert_equal(1, counter('unconfigured'))
  end

  # --- 例外 ---

  def test_exception_is_recorded
    error = RuntimeError.new('boom')
    outcome = @reporter.record_exception(
      sub: SUB, server: 'mstdn.example', announcement_id: '170', error: error,
    )

    assert_equal('exception', outcome)
    assert_equal(:error, last[:level])
    assert_equal(1, counter('exception'))
  end

  # 従来 report_error が出していた 1 行と同じ文言を保つ（既存の grep を壊さない）。
  def test_exception_keeps_the_previous_message_shape
    @reporter.record_exception(
      sub: SUB, server: 'mstdn.example', announcement_id: '170',
      error: RuntimeError.new('boom')
    )

    assert_match(/AnnouncementWorker\[deliver\(ios\)\]: RuntimeError: boom/, last[:payload][:msg])
  end
end
