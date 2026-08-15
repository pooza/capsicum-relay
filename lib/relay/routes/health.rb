require_relative '../base_app'
require_relative '../revision'

module Relay
  module Routes
    # 監視と、デプロイ差分の確認 (#37) の入口。認証は要らない。
    class Health < BaseApp
      get '/health' do
        {
          status: 'ok',
          # Sentry の release と同じ文字列 (Relay::Revision)。変換せずに
          # 突き合わせられる。名乗れないときは null。
          revision: Relay::Revision.current,
          subscriptions: settings.database.count,
          announcement_subscriptions: settings.database.announcement_subscription_count,
          supporters: settings.database.supporter_count,
        }.to_json
      end
    end
  end
end
