require_relative 'announcement_push_outcome'
require_relative 'sentry_setup'

module Relay
  # お知らせ配信 1 通の結末を、構造化ログ 1 行と counter 1 つに落とす (#44)。
  #
  # 通常の push 経路には [Relay::PushHelpers#handle_push_result] があり、
  # success / oversized / permanent / failed を分けて観測している。お知らせ配信
  # ([Relay::AnnouncementWorker#deliver]) にはそれが一切なく、**push クライアント
  # の戻り値を捨てていた**ため、失敗しても journald にも `/metrics` にも Sentry
  # にも何も残らなかった。「お知らせが届かない」という報告が来ても relay 側に
  # 手掛かりが無い、というのが実質いちばん痛い形だった。
  #
  # 結末の**解釈**は [Relay::AnnouncementPushOutcome]（通常 push 経路と同じ順序・
  # 同じ名前）。このクラスは解釈した結果を**どこへ出すか**だけを持つ。
  #
  # ## seen の粒度はこの Issue では触らない（C 案）
  #
  # #44 本文のとおり、`mark_announcement_seen` は **server 単位で購読単位ではない**
  # ため、「失敗したら seen を打たない」と素朴に直すと**そのサーバーの購読者全員へ
  # 再送**になる。購読単位の配送状態を持つ改修（A 案 / B 案）は移行を伴うので、
  # まず観測だけ入れて実際の失敗率を数字で見てから選ぶ。**このクラスは再送を実装
  # しない** — 失敗が「見える」ようにするところまでが役割。
  class AnnouncementDeliveryReporter
    COUNTER = 'relay_announcement_push_total'.freeze
    EVENT = 'announcement.push.result'.freeze

    def initialize(logger:, metrics: nil, database: nil)
      @logger = logger
      @metrics = metrics
      @database = database
    end

    # server ごとの fan-out を 1 行残す。**購読が 0 件でも出す。**
    #
    # #44 の 2026-08-18 のコメントで実際に切り分けコストが出た軸がこれで、
    # 「そもそも購読が無い」「送ったが失敗した」「送って成功した」の 3 択のうち
    # 1 つ目は DB を直接引かないと分からなかった（`announcement_subscriptions` に
    # `macos` が 1 行も無く relay は送りようが無かった、というのが実際の結末）。
    def record_dispatch(server:, announcement_id:, subs:)
      log(
        :info, 'announcement.dispatch',
        msg: "Announcement dispatch: #{server} id=#{announcement_id} subs=#{subs.size}",
        server: server, announcement_id: announcement_id,
        subscriptions: subs.size,
        device_types: subs.map {|sub| sub['device_type']}.tally
      )
    end

    # push クライアントの戻り値 1 つを観測に落とす。返り値は outcome 文字列。
    def record(sub:, server:, announcement_id:, result:)
      outcome = Relay::AnnouncementPushOutcome.classify(result)
      about = {server: server, announcement_id: announcement_id}
      unregister_gone(sub) if outcome == 'gone'
      emit(sub: sub, about: about, outcome: outcome,
        detail: Relay::AnnouncementPushOutcome.detail(result))
      capture(sub: sub, about: about, outcome: outcome, result: result)
      return outcome
    end

    # device_type に対応する push クライアントが設定されていない（または register が
    # 受け付ける device_type に配送が追いついていない）。従来は
    # `return unless @apns` で**黙って捨てていた**ので、「購読行はあるのに 1 通も
    # 届かない」状態が観測に出なかった（#36 の from_settings が起動時に塞いだ穴を、
    # 配送時にも塞ぐ）。設定漏れなら定常的に出るので Sentry へは上げない。
    def record_unconfigured(sub:, server:, announcement_id:, reason: nil)
      emit(
        sub: sub, about: {server: server, announcement_id: announcement_id},
        outcome: 'unconfigured', detail: {reason: reason}.compact
      )
      return 'unconfigured'
    end

    # deliver が例外で落ちた。msg は従来 `report_error` が出していた 1 行と同じ文言に
    # 保つ（journald の既存 grep を壊さない）。
    def record_exception(sub:, server:, announcement_id:, error:)
      emit(
        sub: sub, about: {server: server, announcement_id: announcement_id},
        outcome: 'exception', detail: {reason: error.class.to_s},
        msg: "AnnouncementWorker[deliver(#{sub['device_type']})]: #{error.class}: #{error.message}"
      )
      Relay::SentrySetup.capture_exception(
        error,
        context: {announcement_worker: {
          context: "deliver(#{sub['device_type']})",
          server: server, announcement_id: announcement_id
        }},
      )
      return 'exception'
    end

    private

    def emit(sub:, about:, outcome:, detail:, msg: nil)
      @metrics&.increment(COUNTER, {device_type: sub['device_type'], outcome: outcome})
      log(
        Relay::AnnouncementPushOutcome.level(outcome), EVENT,
        msg: msg || message(sub, about, outcome),
        outcome: outcome,
        device_type: sub['device_type'],
        account: sub['account'],
        **about,
        **detail
      )
    end

    # 人間向けの 1 行。通常 push 側の "Pushed to windows: ..." と同じ読み方が
    # できる形にする（docs/CLAUDE.md「配信不達の切り分け」）。
    def message(sub, about, outcome)
      where = "(#{about[:server]} id=#{about[:announcement_id]})"
      return "Announcement pushed to #{sub['device_type']}: #{sub['account']} #{where}" \
        if outcome == 'success'

      return "Announcement push #{outcome} for #{sub['account']}" \
        " (#{sub['device_type']}, #{about[:server]} id=#{about[:announcement_id]})"
    end

    # 端末が無効化された（UNREGISTERED / BadDeviceToken / WNS 404・410）。この
    # 購読宛には二度と届かないので、お知らせ購読の行を落とす。
    #
    # ⚠ **親 subscription（通常 push 側）はここでは消さない。** 通常 push が同じ
    # 端末で 404 / 410 を踏めば [Relay::PushHelpers#handle_push_gone] が
    # `Database#unregister` を呼び、お知らせ購読も FK の CASCADE で一緒に消える。
    # お知らせ配信だけを根拠に親を消すと、**通常 push は生きているのに端末ごと
    # 登録解除する**危険がある（お知らせ payload 固有の失敗を端末の死と取り違える）。
    def unregister_gone(sub)
      id = sub['announcement_subscription_id']
      return if id.nil? || @database.nil?

      @database.unregister_announcement_subscription(id)
    end

    # ⚠ **判定は `LEVELS` の引きではなく [AnnouncementPushOutcome.level] で行う**
    # （Codex P2 / PR #51）。`wns_channelthrottled` のような **動的に組む outcome は
    # `LEVELS` に載っていない**ので、Hash を直接引くと nil になり Sentry へ 1 件も
    # 上がらなかった。通常 push 側 ([Relay::PushHelpers#handle_wns_status]) は
    # 非正常な WNS ステータスを明示的に capture しており、そこと非対称になる。
    #
    # 除外は 2 つ:
    # - `:info`（success / gone / `wns_dropped` 等の正常系）。通常 push 側も
    #   handle_push_gone で Sentry へは上げていない
    # - `unconfigured`（設定漏れ・配線漏れ）。直るまで定常的に出続けるので alert に
    #   向かない。journald と counter には残る
    def capture(sub:, about:, outcome:, result:)
      level = Relay::AnnouncementPushOutcome.level(outcome)
      return if level == :info || outcome == 'unconfigured'

      Relay::SentrySetup.capture_message(
        "Announcement push #{outcome} (#{sub['device_type']})",
        level: level == :error ? :error : :warning,
        context: {announcement_push: context(sub, about, result)},
      )
    end

    def context(sub, about, result)
      return {
        device_type: sub['device_type'],
        account: sub['account'],
        token: Relay::SentrySetup.mask_token(sub['token']),
      }.merge(about).merge(Relay::AnnouncementPushOutcome.detail(result)).compact
    end

    # worker は request scope の外なので request_id は無い。event / msg の形は
    # [Relay::BaseApp] の log_event と揃える。
    def log(level, event, msg:, **fields)
      @logger.public_send(level, {event: event, msg: msg}.merge(fields))
    end
  end
end
