require 'apnotic'
require 'logger'

module Relay
  class ApnsClient
    # APNs が返す reason のうち「デバイストークン自体が無効」を示すもの。
    # これらを受けた場合、relay は Mastodon に HTTP 410 Gone を返して
    # subscription を destroy してもらい、自らの row も削除する。
    PERMANENT_REASONS = ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'].freeze
    # APNs payload 上限 (alert push 4KB) 超過。subscription は健全なので
    # unregister せず、該当 1 通だけドロップする (#9)。
    OVERSIZED_REASONS = ['PayloadTooLarge'].freeze

    def initialize(config, logger: Logger.new($stdout))
      @config = config
      @logger = logger
      options = {
        auth_method: :token,
        cert_path: config['apns']['key_path'],
        key_id: config['apns']['key_id'],
        team_id: config['apns']['team_id'],
      }
      if config['apns']['sandbox']
        @connection = Apnotic::Connection.development(options)
      else
        @connection = Apnotic::Connection.new(options)
      end
      register_error_callback(@connection)
    end

    def push(device_token:, payload:)
      response = @connection.push(build_notification(device_token, payload))
      return {success: true, id: response.headers['apns-id']} if response&.ok?

      reason = response&.body&.dig('reason')
      return {
        success: false,
        status: response&.status,
        reason: reason,
        permanent: PERMANENT_REASONS.include?(reason),
        oversized: OVERSIZED_REASONS.include?(reason),
      }
    end

    def close
      return @connection&.close
    end

    private

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
      end
    end

    def build_notification(device_token, payload)
      notification = Apnotic::Notification.new(device_token)
      notification.topic = @config['apns']['bundle_id']
      notification.alert = {
        title: 'capsicum',
        body: "#{payload['account']} に通知があります",
      }
      notification.sound = 'default'
      notification.mutable_content = true
      notification.custom_payload = payload
      notification.push_type = 'alert'
      return notification
    end
  end
end
