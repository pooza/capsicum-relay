require_relative '../base_app'
require_relative '../wns_client'

module Relay
  module Routes
    # 端末トークンの登録 / 解除。capsicum の PushRegistrationService が叩く。
    class Register < BaseApp
      DEVICE_TYPES = ['ios', 'android', 'macos', 'windows'].freeze

      post '/register' do
        authenticate!
        require_fields!('token', 'device_type', 'account', 'server')
        validate_device_type!

        # device_id は任意。送ってこない旧クライアントは従来どおり token をキーに
        # 登録される (#15 / capsicum#932)。
        sub = settings.database.register(
          token: json_body['token'],
          device_type: json_body['device_type'],
          account: json_body['account'],
          server: json_body['server'],
          device_id: json_body['device_id'],
        )

        settings.logger.info(
          "Registered: #{sub['account']} (#{sub['device_type']}," \
            " device_id=#{sub['device_id'] ? 'yes' : 'none'})",
        )
        status 201
        sub.to_json
      end

      delete '/register/:id' do
        authenticate!

        sub = settings.database.unregister(params[:id].to_i)
        halt 404, {error: 'Not found'}.to_json unless sub

        settings.logger.info("Unregistered: #{sub['account']}")
        sub.to_json
      end

      helpers do
        def validate_device_type!
          unless DEVICE_TYPES.include?(json_body['device_type'])
            halt 400, {error: 'device_type must be ios, android, macos or windows'}.to_json
          end

          # windows の token は WNS Channel URI。任意ホストを保存すると /push で
          # そこへ Bearer + payload 付き POST をさせられる (SSRF) ため、入口で WNS
          # ホストに限定する (#21 / capsicum#474 レビュー)。
          return unless json_body['device_type'] == 'windows'
          return if Relay::WnsClient.valid_channel_uri?(json_body['token'])

          halt 400, {error: 'token must be a WNS channel URI (*.notify.windows.com)'}.to_json
        end
      end
    end
  end
end
