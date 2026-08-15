require_relative '../base_app'

module Relay
  module Routes
    # 投げ銭の記録と参照 (capsicum#596 / #18)。
    class Supporters < BaseApp
      # (account, server) 単位の upsert。tipped_at はローカル既存レコードの
      # 汲み上げ（バックフィル）用で、省略時・解釈不能時は現在時刻。
      post '/supporters/tip' do
        authenticate!
        require_fields!('account', 'server')

        count = json_body.fetch('count', 1)
        unless count.is_a?(Integer) && count.positive?
          halt 400, {error: 'count must be a positive integer'}.to_json
        end

        supporter = settings.database.record_supporter_tip(
          account: json_body['account'],
          server: json_body['server'],
          sku: json_body['sku'],
          tipped_at: json_body['tipped_at'],
          count: count,
        )

        settings.logger.info(
          "Supporter tip recorded: #{supporter['account']} (count=#{count})",
        )
        status 201
        supporter.to_json
      end

      get '/supporters' do
        authenticate!

        account = params['account'].to_s
        server = params['server'].to_s
        if account.empty? || server.empty?
          halt 400, {error: 'account and server are required'}.to_json
        end

        supporter = settings.database.find_supporter(account: account, server: server)
        halt 404, {error: 'Not found'}.to_json unless supporter

        supporter.to_json
      end
    end
  end
end
