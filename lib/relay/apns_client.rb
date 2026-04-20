require 'apnotic'

module Relay
  class ApnsClient
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
        { success: true, id: response.headers['apns-id'] }
      else
        {
          success: false,
          status: response&.status,
          reason: response&.body&.dig('reason'),
        }
      end
    end

    def close
      @connection&.close
    end
  end
end
