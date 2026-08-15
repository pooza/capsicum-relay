require 'base64'
require 'json'
require_relative 'sentry_setup'

module Relay
  # App から push 送信・結果ハンドリング系を切り出した Sinatra helper mixin (#27)。
  # App では `helpers Relay::PushHelpers` で混ぜる。Sinatra の helpers はモジュール
  # の mixin なので、`settings` / `request` / `halt` / `status` の request scope は
  # 移動後もそのまま効く。ロジックの書き換えは伴わない、ほぼ純粋な移動。
  module PushHelpers
    # WNS が HTTP 200 でも X-WNS-NotificationStatus に返しうる、received 以外の
    # ステータスのうち **正常系** のもの。dropped は「端末がオフライン / スリープで
    # 受け取れなかった」で、raw notification は queue されないため必ずこうなる。
    # PC を消している時間の方が長い利用者ほど通知量に比例して積み上がり、Sentry へ
    # 上げると本当の異常（channelthrottled・鍵不在・復号失敗）が埋もれる
    # (#24。5.5 週で 4476 件たまった)。journald には残すので、成功ログ
    # (Pushed to windows:) との突き合わせによる切り分けは引き続きできる
    # （手順は docs/CLAUDE.md「配信不達の切り分け」）。
    WNS_BENIGN_STATUSES = ['dropped'].freeze

    # push 1 通の結末を、構造化ログ 1 行と counter 1 つに落とす (#2)。
    #
    # ⚠ **outcome はここを唯一の出口にする。** 従来は結末ごとに logger 呼び出しが
    # 散っていて、新しい結末を足すたびに計装を書き忘れる形だった（WNS の
    # `dropped` が長らく件数として見えなかったのがそれ）。
    #
    # `msg` は従来と同じ文言。docs/CLAUDE.md「配信不達の切り分け」の grep 手順を
    # 壊さないため（Relay::StructuredLog 参照）。
    def record_push_outcome(sub, outcome, msg:, level: :info, **fields)
      metrics.increment(
        'relay_push_total', {device_type: sub['device_type'], outcome: outcome}
      )
      log_event(
        'push.result', msg: msg, level: level,
        outcome: outcome,
        device_type: sub['device_type'],
        account: sub['account'],
        server: sub['server'],
        latency_ms: latency_ms,
        **fields
      )
    end

    def build_push_payload(sub)
      payload = {
        'body' => Base64.strict_encode64(request.body.read),
        'encoding' => request.env['HTTP_CONTENT_ENCODING'].to_s,
        'server' => sub['server'],
        'account' => sub['account'],
      }
      # aes128gcm は body 先頭に salt / sender public key が埋まるので body と
      # encoding で足りるが、レガシー aesgcm は Crypto-Key / Encryption ヘッダに
      # 入るため、存在すれば転送する（旧 Mastodon / 一部 Misskey 対応）。
      crypto_key = request.env['HTTP_CRYPTO_KEY']
      encryption_header = request.env['HTTP_ENCRYPTION']
      payload['crypto_key'] = crypto_key if crypto_key
      payload['encryption'] = encryption_header if encryption_header
      return payload
    end

    def dispatch_push(sub, payload)
      client, name = push_client_for(sub['device_type'])
      halt 503, {error: "#{name} not configured"}.to_json unless client
      return client.push(device_token: sub['token'], payload: payload)
    end

    # device_type ごとの送信クライアントと表示名を返す。各クライアントは
    # push(device_token:, payload:) を共通 I/F に持つ。未設定なら client は nil。
    def push_client_for(device_type)
      case device_type
      when 'ios', 'macos'
        # macOS は iOS と同一 Bundle ID + 同一 APNs Auth Key で動くため、同じ
        # APNs クライアントに流す (capsicum#468)。
        [(settings.apns if settings.respond_to?(:apns)), 'APNs']
      when 'android'
        [(settings.fcm if settings.respond_to?(:fcm)), 'FCM']
      when 'windows'
        # Windows は WNS raw push。token は Channel URI。relay は暗号文を復号せず
        # payload をそのまま転送し、bg task が復号する (capsicum#474)。
        [(settings.wns if settings.respond_to?(:wns)), 'WNS']
      end
    end

    def log_push_received(sub)
      log_event(
        'push.received',
        msg: push_received_message(sub),
        device_type: sub['device_type'],
        account: sub['account'],
        server: sub['server'],
        # ⚠ push_token は capability secret。指紋だけ残す。
        push_token: Relay::StructuredLog.fingerprint(sub['push_token']),
        **push_received_fields,
      )
    end

    # 各サーバーがどの暗号化形式で送ってくるかを diagnose できるようにする (#5)。
    # len / topic は dedup (#16) の判別材料の効きを後追いするための観測で、同一
    # 通知の重複バーストが同一 len かつ別通知が別 len になっているかを見てから
    # 窓・キーを調整する。機密情報は含まないため常時出力。
    def push_received_fields
      return {
        encoding: request.env['HTTP_CONTENT_ENCODING'].to_s,
        has_crypto_key: !request.env['HTTP_CRYPTO_KEY'].nil?,
        has_encryption: !request.env['HTTP_ENCRYPTION'].nil?,
        has_topic: !request.env['HTTP_TOPIC'].nil?,
        # Rack は String で返す。jq で数値比較したいので整数に寄せる。
        length: request.content_length&.to_i,
      }
    end

    # 従来と同じ 1 行。docs/CLAUDE.md「配信不達の切り分け」の grep 手順を壊さない。
    def push_received_message(sub)
      fields = push_received_fields
      flags = [
        (fields[:has_crypto_key] ? '+ck' : ''),
        (fields[:has_encryption] ? '+enc' : ''),
      ].join
      topic = fields[:has_topic] ? '+topic' : ''
      return "Received push: #{sub['account']} (#{sub['device_type']}," \
        " encoding=#{fields[:encoding].inspect}#{flags}" \
        " len=#{fields[:length]}#{topic})"
    end

    def handle_push_result(sub, result)
      return handle_push_delivered(sub, result) if result[:success]
      return handle_push_oversized(sub, result) if result[:oversized]
      return handle_push_gone(sub, result) if result[:permanent]
      return handle_push_failed(sub, result)
    end

    # Sentry に載せる push 失敗コンテキスト。token は部分マスクし、生のレスポンス
    # body（FCM のエラー JSON 等）は status / reason に絞って送る (#10 Phase B/E)。
    def push_context(sub, result)
      {
        device_type: sub['device_type'],
        account: sub['account'],
        server: sub['server'],
        token: Relay::SentrySetup.mask_token(sub['token']),
        status: result[:status],
        reason: result[:reason],
        # reason を採れない非 JSON 応答のときだけ入る、切り詰めた生 body
        # (#25)。compact されるので通常の失敗では出ない。
        body_snippet: result[:body_snippet],
      }.compact
    end

    def handle_push_delivered(sub, result = {})
      wns_status = result[:wns_status]
      return handle_wns_status(sub, result, wns_status) if wns_status && wns_status != 'received'
      return handle_push_degraded(sub, result) if result[:degraded]

      record_push_outcome(sub, 'success', msg: "Pushed to #{sub['device_type']}: #{sub['account']}")
      return {status: 'delivered'}.to_json
    end

    # 暗号化 payload が上限を超えたため汎用文面だけ届けた (#17)。以前は 1 通まるごと
    # drop していた（端末に何も出ない）ので、**ここに来るのは改善後の正常系**。ただし
    # 「本文の読めない通知」ではあり、送信側の payload 設計が肥大していないかを追う
    # 材料になるので warning として件数を観測する。drop (Push oversized dropped) とは
    # 別メッセージにして、本当の不達が 0 になったことを確認できるようにする。件数が
    # 青天井になるようなら WNS_BENIGN_STATUSES と同じくログのみへ落とす。
    def handle_push_degraded(sub, result)
      record_push_outcome(
        sub, 'degraded', level: :warn,
        msg: "Push degraded to generic alert: #{sub['account']}" \
          " (#{sub['device_type']}, #{result[:original_size]}B)",
        original_size: result[:original_size]
      )
      Relay::SentrySetup.capture_message(
        "Push oversized degraded (#{sub['device_type']})",
        level: :warning,
        context: {push: push_context(sub, result).merge(original_size: result[:original_size])},
      )
      return {status: 'delivered', degraded: true}.to_json
    end

    # 配信は受理扱い（success）だが実質的な不達。WNS 固有の静かな失敗モードで、
    # ここを観測しないと Windows push 不達の切り分けで効かない (#474 レビュー)。
    # ただし正常系（WNS_BENIGN_STATUSES）は件数が青天井なので Sentry へは上げず、
    # ログだけに残す。
    def handle_wns_status(sub, result, wns_status)
      benign = WNS_BENIGN_STATUSES.include?(wns_status)
      message = "WNS delivered but #{wns_status}: #{sub['account']}"
      record_push_outcome(
        sub, "wns_#{wns_status}", level: benign ? :info : :warn,
        msg: message, wns_status: wns_status
      )
      unless benign
        Relay::SentrySetup.capture_message(
          "WNS notification #{wns_status} (windows)",
          level: :warning,
          context: {push: push_context(sub, result).merge(wns_status: wns_status)},
        )
      end
      return {status: 'delivered', wns_status: wns_status}.to_json
    end

    def handle_push_gone(sub, result)
      # Device token が無効化された（UNREGISTERED / BadDeviceToken 等）。
      # Mastodon には 410 を返して subscription を destroy してもらい、
      # relay 側の行も掃除する。
      settings.database.unregister(sub['id'])
      reason = result[:reason] || result[:status]
      record_push_outcome(
        sub, 'gone',
        msg: "Subscription gone: #{sub['account']} (#{reason})", reason: reason
      )
      status 410
      return {status: 'gone', detail: result}.to_json
    end

    def handle_push_oversized(sub, result)
      # FCM (4KB) / APNs (4KB) のペイロード上限を超えた個別メッセージ。
      # subscription は健全なので unregister せず、Mastodon にも 413 を
      # 返してこの 1 通だけドロップさせる。permanent: false のままだと
      # Mastodon が retry を続けてログを汚すため、ここで明示的に止める (#9)。
      record_push_outcome(
        sub, 'oversized', level: :warn,
        msg: "Push oversized (subscription kept): #{sub['account']}" \
          " (#{sub['device_type']}): #{result}",
        reason: result[:reason] || result[:status]
      )
      # 健全な subscription を残したまま 1 通だけドロップする想定挙動だが、
      # 多発は送信側のペイロード設計問題を示すので warning として件数観測する
      # (#10 Phase B、#9 の後継観測)。
      Relay::SentrySetup.capture_message(
        "Push oversized dropped (#{sub['device_type']})",
        level: :warning,
        context: {push: push_context(sub, result)},
      )
      status 413
      return {status: 'oversized', detail: result}.to_json
    end

    def handle_push_failed(sub, result)
      record_push_outcome(
        sub, 'failed', level: :error,
        msg: "Push failed: #{result}", reason: result[:reason] || result[:status]
      )
      # 一過性でない送信失敗（APNs / FCM の 5xx 等）。低頻度・高インパクトなので
      # journalctl 任せにせず Sentry で alert 駆動にする (#10 Phase B、#8 の後継観測)。
      Relay::SentrySetup.capture_message(
        "Push delivery failed (#{sub['device_type']})",
        level: :error,
        context: {push: push_context(sub, result)},
      )
      status 502
      return {status: 'failed', detail: result}.to_json
    end
  end
end
