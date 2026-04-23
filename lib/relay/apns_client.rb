require 'apnotic'

module Relay
  class ApnsClient
    # APNs が返す reason のうち「デバイストークン自体が無効」を示すもの。
    # これらを受けた場合、relay は Mastodon に HTTP 410 Gone を返して
    # subscription を destroy してもらい、自らの row も削除する。
    PERMANENT_REASONS = ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'].freeze

    def initialize(config)
      @config = config
      options = {
        auth_method: :token,
        cert_path: config['apns']['key_path'],
        key_id: config['apns']['key_id'],
        team_id: config['apns']['team_id'],
      }
      @connection = if config['apns']['sandbox']
        Apnotic::Connection.development(options)
      else
        Apnotic::Connection.new(options)
      end
    end

    def push(device_token:, payload:)
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

      response = @connection.push(notification)

      if response&.ok?
        {success: true, id: response.headers['apns-id']}
      else
        reason = response&.body&.dig('reason')
        {
          success: false,
          status: response&.status,
          reason: reason,
          permanent: PERMANENT_REASONS.include?(reason),
        }
      end
    end

    def close
      @connection&.close
    end
  end
end
