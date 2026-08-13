require 'apnotic'
require 'logger'
require 'monitor'
require_relative 'apns_payload'
require_relative 'sentry_setup'

module Relay
  class ApnsClient
    # APNs が返す reason のうち「デバイストークン自体が無効」を示すもの。
    # これらを受けた場合、relay は Mastodon に HTTP 410 Gone を返して
    # subscription を destroy してもらい、自らの row も削除する。
    PERMANENT_REASONS = ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'].freeze
    # degrade しても上限を割れず、送信前に倒したときの合成 reason (#17)。下流
    # (handle_push_oversized) の扱いを APNs 実応答の 413 と揃えるため、下の
    # OVERSIZED_REASONS に同居させる。
    OVERSIZED_PRECHECK_REASON = 'PayloadTooLarge (pre-check)'.freeze
    # APNs payload 上限 (alert push 4KB) 超過。subscription は健全なので
    # unregister せず、該当 1 通だけドロップする (#9)。
    OVERSIZED_REASONS = ['PayloadTooLarge', OVERSIZED_PRECHECK_REASON].freeze
    # 送信前に倒すときに載せる HTTP ステータス。APNs の 413 に合わせる。
    OVERSIZED_STATUS = 413
    # 非 JSON の失敗応答は HTML のエラーページ全文でありうるので、切り分けに
    # 足りる長さだけ残してログ / Sentry へ載せる (#25)。
    BODY_SNIPPET_LIMIT = 200

    def initialize(config, logger: Logger.new($stdout))
      @config = config
      @logger = logger
      @mon = Monitor.new
      @payload = Relay::ApnsPayload.new(config['apns']['bundle_id'])
      @connection = build_connection
    end

    # 送信経路の例外は握って failure を返す。素通りさせると Sinatra が 500 を
    # 返し、上流に「配信失敗」ではなく「relay が壊れた」と見えるうえ、
    # permanent / oversized の判定（無効トークンの掃除・1 通ドロップ）にも
    # 到達しなくなるため (#25 / #26)。
    # 上限超過時に暗号化 body を外した汎用文面へ倒す degrade は ApnsPayload が判断する
    # (#17)。Notification は 1 回だけ組み立てて再送でも使い回す。apns-id が同じままに
    # なり、StreamLimit 再送が二重配信に見えるのを避けられる。
    def push(device_token:, payload:, alert: nil)
      connection = @connection
      built = @payload.build(device_token: device_token, payload: payload, alert: alert)
      return oversized_precheck_result(built) unless built.notification

      log_degrade(built) if built.degraded_from
      return deliver(connection, built.notification, degraded_from: built.degraded_from)
    rescue HTTP2::Error::StreamLimitExceeded => e
      return push_after_reset(connection, e, built)
    end

    def close
      return @connection&.close
    end

    private

    def deliver(connection, notification, degraded_from: nil)
      response = connection.push(notification)
      return delivered(response, degraded_from) if response&.ok?

      return failure(
        status: response&.status,
        reason: reason_of(response),
        body_snippet: body_snippet_of(response),
      )
    end

    # degrade して送ったときだけ degraded / original_size を添える。上位
    # (handle_push_delivered) が「届いたが本文は読めない」を観測するのに使う。
    def delivered(response, degraded_from)
      result = {success: true, id: response.headers['apns-id']}
      return result unless degraded_from

      return result.merge(degraded: true, original_size: degraded_from)
    end

    def log_degrade(built)
      @logger.warn(
        "APNs payload degraded to generic alert: #{built.degraded_from}B" \
          " > #{Relay::ApnsPayload::PAYLOAD_LIMIT}B (sent #{built.byte_size}B)",
      )
    end

    # degrade しても上限を割れない稀なケース（account 名だけで 4KB を超える等）。
    # 事後の 413 応答と同型 (oversized: true) を返し、handle_push_oversized の
    # drop + 観測へそのまま倒す。WNS の同名メソッド (#21) と役割を揃えている。
    def oversized_precheck_result(built)
      @logger.warn(
        "APNs payload too large after degrade: #{built.byte_size}B" \
          " > #{Relay::ApnsPayload::PAYLOAD_LIMIT}B",
      )
      return failure(status: OVERSIZED_STATUS, reason: OVERSIZED_PRECHECK_REASON)
    end

    # ストリーム上限は接続を張り直さないと戻らないので、作り直して 1 回だけ
    # 送り直す。`HTTP2::Connection#new_stream` はバイトを 1 つも送る前に raise
    # するため、この再送で二重配信にはならない。2 回目も上限に当たったら
    # failure に落として上流の再送に委ねる（handle_push_failed → 502）。
    def push_after_reset(stale, error, built)
      @logger.warn(
        'APNs stream limit reached; reconnecting and retrying once:' \
          " #{error.class}: #{error.message}",
      )
      return deliver(
        reset_connection(stale), built.notification, degraded_from: built.degraded_from
      )
    rescue HTTP2::Error::StreamLimitExceeded
      return failure(status: nil, reason: 'StreamLimitExceeded')
    end

    def failure(status:, reason:, body_snippet: nil)
      return {
        success: false,
        status: status,
        reason: reason,
        permanent: PERMANENT_REASONS.include?(reason),
        oversized: OVERSIZED_REASONS.include?(reason),
        body_snippet: body_snippet,
      }
    end

    # `Apnotic::Response#body` は JSON parse に失敗すると生の String をそのまま
    # 返す（apnotic-1.8.0 の `JSON.parse(@body) rescue @body`）。失敗応答が非
    # JSON（空 body / HTML のエラーページ等）だと dig が NoMethodError で落ちて
    # push が 500 になっていたので、Hash のときだけ reason を採る (#25)。
    def reason_of(response)
      body = response&.body
      return body['reason'] if body.is_a?(Hash)
      return nil
    end

    # reason を採れなかった非 JSON 応答は、何が返ってきたのかを残さないと
    # 次に踏んだとき同じ調査をやり直すことになる (#25)。
    def body_snippet_of(response)
      body = response&.body
      return nil if body.nil? || body.is_a?(Hash)

      text = body.to_s.strip
      return nil if text.empty?
      return text[0, BODY_SNIPPET_LIMIT]
    end

    # 上限に当たった接続を捨てて張り直す。net-http2 の自動再接続は socket 例外
    # にしか反応しない（#8 の `init_vars` 経路）ため、socket が生きたまま raise
    # するこのケースでは明示的に差し替える必要がある (#26)。同時に複数スレッドが
    # 踏んでも張り直しは 1 回だけになるよう、掴んでいた接続がまだ現役のときしか
    # 差し替えない。
    def reset_connection(stale)
      replaced = false
      fresh = @mon.synchronize do
        if @connection.equal?(stale)
          @connection = build_connection
          replaced = true
        end
        @connection
      end
      close_quietly(stale) if replaced
      return fresh
    end

    # 上限に当たった接続の close は、相手がすでに GOAWAY を送っている等で例外に
    # なりうる。差し替えは済んでいるので握り潰してよい。
    def close_quietly(connection)
      connection&.close
    rescue StandardError => e
      @logger.warn("APNs connection close failed (ignored): #{e.class}: #{e.message}")
    end

    def build_connection
      options = {
        auth_method: :token,
        cert_path: @config['apns']['key_path'],
        key_id: @config['apns']['key_id'],
        team_id: @config['apns']['team_id'],
      }
      connection = if @config['apns']['sandbox']
        Apnotic::Connection.development(options)
      else
        Apnotic::Connection.new(options)
      end
      register_error_callback(connection)
      return connection
    end

    # net-http2 が socket_loop スレッド内で raise した SocketError / EOFError を
    # ここで吸う。callback 未登録だと socket_loop スレッドが abort_on_exception=true
    # で raise し、puma プロセス全体を落とす（systemd 再起動で救われている脆い
    # 安定状態。観測時刻 2026-04-24 03:13:40 JST、APNs idle timeout 由来 #8）。
    # callback 登録時、net-http2 client.rb は init_vars で @socket_thread を
    # nil にした状態で emit するため、次回 push() 時の ensure_open が
    # 自動で再接続する。手動再構築は不要。
    def register_error_callback(connection)
      connection.on(:error) do |error|
        @logger.warn(
          "APNs connection error (background): #{error.class}: #{error.message}",
        )
        # socket_loop スレッドの例外は Rack middleware の外（スレッド境界の先）で
        # 起きるため、明示捕捉しないと Sentry に上がらない。#8 の本丸 (#10 Phase C)。
        Relay::SentrySetup.capture_exception(error, context: {apns: {source: 'socket_loop'}})
      end
    end
  end
end
