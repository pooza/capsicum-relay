require 'apnotic'

module Relay
  class ApnsClient
    def initialize(config)
      @config = config
      connection_class = config['apns']['sandbox'] ? Apnotic::Connection::Development : Apnotic::Connection
      @connection = connection_class.new(
        auth_method: :token,
        cert_path: config['apns']['key_path'],
        key_id: config['apns']['key_id'],
        team_id: config['apns']['team_id']
      )
    end

    def push(device_token:, payload:)
      notification = Apnotic::Notification.new(device_token)
      notification.topic = @config['apns']['bundle_id']
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
