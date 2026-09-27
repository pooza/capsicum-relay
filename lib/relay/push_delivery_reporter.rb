require_relative 'push_outcome'
require_relative 'sentry_setup'
require_relative 'structured_log'

module Relay
  # 通常の push（上流からの中継）1 通の結末を観測に落とす (#55)。
  #
  # ⚠⚠ **request scope の外で動く。**#55 で配送をワーカーへ移したので、結末が
  # 出るのは HTTP 応答を返した**後**になる。従来は
  # [Relay::PushHelpers#handle_push_result] が `status` / `halt` と一体で、
  # **観測と HTTP 応答が同じ関数に混ざっていた**ため worker から呼べなかった。
  #
  # ## ⚠ 「outcome はここを唯一の出口にする」は保つ
  #
  # 結末ごとにログ呼び出しが散っていると、新しい結末を足すたびに計装を書き忘れる
  # （WNS の `dropped` が長らく件数として見えなかったのがそれ・#24）。解釈は
  # [Relay::PushOutcome]、出力はこのクラスの [#record] 1 本。
  #
  # ## ⚠⚠ 上流へ結末を返す手段はもう無い
  #
  # 非同期なので、`gone`（device token が無効）を踏んでも**そのリクエストでは
  # 410 を返せない**。代わりに [Relay::Database#unregister] で relay 側の行を
  # 落とし、**次の push が `410 Unknown push token` を返す**ことで上流の購読が
  # 掃除される（`routes/push.rb` の `halt_unknown_push_token!`）。
  # ⚠ **1 通だけ「受け取ったのに届かない」通知が出る**のは承知の上のコスト。
  class PushDeliveryReporter
    COUNTER = 'relay_push_total'.freeze
    EVENT = 'push.result'.freeze

    # ⚠⚠ **[logger] は Proc でも渡せる。**構築時に握ると、あとから
    # `set :logger` しても差し替わらない —— `Database` や各 push クライアントが
    # 抱えている罠と同じ（`BaseApp` の `configure` のコメント）。**配送ログは
    # 観測の中心**なので、ここだけは毎回引き直せる形にしておく
    # （テストが差し替えた logger に `push.result` が出ないと、**ログの内容を
    # 検証するテストが黙って素通りする**）。
    def initialize(logger:, metrics: nil, database: nil)
      @logger = logger
      @metrics = metrics
      @database = database
    end

    def logger
      return @logger.respond_to?(:call) ? @logger.call : @logger
    end

    # [result] は push クライアントの戻り値。[latency_ms] は配送にかかった時間
    # （⚠ **受信からではなく配送から**測る。キューで待った時間は [#record_queued]
    # 側の `queued_ms` に出る）。返り値は outcome 文字列。
    def record(sub:, result:, latency_ms: nil, request_id: nil, queued_ms: nil)
      outcome = Relay::PushOutcome.classify(result)
      unregister_gone(sub) if outcome == 'gone'
      emit(
        sub: sub, outcome: outcome, result: result,
        timing: {
          request_id: request_id, latency_ms: latency_ms, queued_ms: queued_ms
        }
      )
      capture(sub: sub, outcome: outcome, result: result)
      return outcome
    end

    # 配送そのものが例外で落ちた。⚠ **握りつぶさない** —— ワーカーのスレッドが
    # 例外で死ぬと**以降の push が全部キューに溜まって消える**ので、呼び出し側は
    # 必ずここを通してから次の 1 通へ進む。
    def record_exception(sub:, error:, request_id: nil)
      emit(
        sub: sub, outcome: 'exception', result: {reason: error.class.to_s},
        timing: {request_id: request_id}
      )
      Relay::SentrySetup.capture_exception(
        error, context: {push: context(sub, {})}
      )
      return 'exception'
    end

    # 重複を抑止した (capsicum#692 / #16)。⚠ **上流には成功として返す**
    # （4xx / 5xx だと retry や購読の destroy を誘発する）。
    def record_deduped(sub:, request_id: nil, latency_ms: nil)
      emit(
        sub: sub, outcome: 'deduped', result: {},
        timing: {request_id: request_id, latency_ms: latency_ms}
      )
      return 'deduped'
    end

    # キューが満杯で受け取れなかった (#55)。⚠ **上流には 5xx を返す**ので、
    # Mastodon は retry する（4xx にすると購読が消える・#66）。
    def record_rejected(sub:, depth:, request_id: nil)
      emit(
        sub: sub, outcome: 'rejected', result: {reason: 'queue_full'},
        timing: {request_id: request_id}
      )
      # ⚠ **満杯は異常。**配送が詰まっている（WNS の障害等）合図なので Sentry へ。
      Relay::SentrySetup.capture_message(
        'Push queue full (rejected)',
        level: :error,
        context: {push: context(sub, {}).merge(queue_depth: depth)},
      )
      return 'rejected'
    end

    private

    # [timing] は `request_id` / `latency_ms` / `queued_ms`。
    #
    # ⚠ **`queued_ms` = キューで待った時間 (#55)。**配送が詰まっているかは
    # `latency_ms` では分からない（1 通あたりの速さは変わらないので）。詰まりは
    # ここに出る。
    def emit(sub:, outcome:, result:, timing: {})
      @metrics&.increment(COUNTER, {device_type: sub['device_type'], outcome: outcome})
      log(
        Relay::PushOutcome.level(outcome),
        msg: message(sub, outcome, result),
        outcome: outcome,
        device_type: sub['device_type'],
        account: sub['account'],
        server: sub['server'],
        conn: result.is_a?(Hash) ? result[:conn] : nil,
        **timing,
        **Relay::PushOutcome.detail(result),
      )
    end

    # ⚠⚠ **人間向けの 1 行は従来の文言をそのまま保つ。**
    # `docs/CLAUDE.md`「配信不達の切り分け」の手順は journald を
    # `grep "Pushed to windows:"` する形で回っており、文言を変えるとその手順が死ぬ。
    def message(sub, outcome, result)
      case outcome
      when 'success' then "Pushed to #{sub['device_type']}: #{sub['account']}"
      when 'degraded'
        "Push degraded to generic alert: #{sub['account']}" \
          " (#{sub['device_type']}, #{result[:original_size]}B)"
      when 'gone'
        reason = result[:reason] || result[:status]
        "Subscription gone: #{sub['account']} (#{reason})"
      when 'oversized'
        "Push oversized (subscription kept): #{sub['account']}" \
          " (#{sub['device_type']}): #{result}"
      when 'deduped'
        "Push deduped (#{sub['device_type']}): #{sub['account']}"
      when 'rejected'
        "Push rejected (queue full): #{sub['account']} (#{sub['device_type']})"
      when 'exception'
        "Push raised: #{sub['account']} (#{sub['device_type']}): #{result[:reason]}"
      when 'failed' then "Push failed: #{result}"
      else "Push #{outcome}: #{sub['account']} (#{sub['device_type']})"
      end
    end

    # ⚠ **`gone` のときだけ relay 側の行を落とす。**これが次の push の 410 の
    # 引き金になり、上流の購読が掃除される（クラスの doc を参照）。
    #
    # ⚠⚠ **積んだ時点のトークンと一致するときだけ消す**（PR #67 の Codex P1）。
    # `update_registration` は**行 ID を保ったまま `token` を差し替える**ので、
    # 配送の待ち時間中に `/register` で端末のトークンが更新されていたら、
    # **いま有効な登録を消してしまう**（理由は
    # [Relay::Database#unregister_stale] の doc）。
    def unregister_gone(sub)
      return if sub['id'].nil? || @database.nil?

      @database.unregister_stale(sub['id'], sub['token'])
    end

    # ⚠ 判定は [PushOutcome.level] で行う（`LEVELS` を直接引くと、動的に組む
    # `wns_channelthrottled` 等が nil になって 1 件も上がらない・Codex P2 / PR #51）。
    # ⚠ `gone` は正常系なので上げない（従来の `handle_push_gone` と同じ）。
    def capture(sub:, outcome:, result:)
      level = Relay::PushOutcome.level(outcome)
      return if level == :info

      Relay::SentrySetup.capture_message(
        "Push #{outcome} (#{sub['device_type']})",
        level: level == :error ? :error : :warning,
        context: {push: context(sub, result)},
      )
    end

    # ⚠ 生のレスポンス body は載せない。token は部分マスク (#10 Phase B/E)。
    def context(sub, result)
      return {
        device_type: sub['device_type'],
        account: sub['account'],
        server: sub['server'],
        token: Relay::SentrySetup.mask_token(sub['token']),
      }.merge(Relay::PushOutcome.detail(result)).compact
    end

    # ⚠ worker は request scope の外なので `request_id` は引数で受け取る
    # （受信時のリクエストと突き合わせるための取っ手・#2）。
    def log(level, msg:, **fields)
      logger.public_send(level, {event: EVENT, msg: msg}.merge(fields).compact)
    end
  end
end
