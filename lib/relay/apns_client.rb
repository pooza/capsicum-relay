require 'apnotic'

module Relay
  class ApnsClient
    # APNs が返す reason のうち「デバイストークン自体が無効」を示すもの。
    # これらを受けた場合、relay は Mastodon に HTTP 410 Gone を返して
    # subscription を destroy してもらい、自らの row も削除する。
    PERMANENT_REASONS = ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'].freeze
    # APNs payload 上限 (alert push 4KB) 超過。subscription は健全なので
    # unregister せず、該当 1 通だけドロップする (#9)。
    OVERSIZED_REASONS = ['PayloadTooLarge'].freeze

    def initialize(config)
      @config = config
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
