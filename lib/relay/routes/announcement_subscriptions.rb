require_relative '../base_app'

module Relay
  module Routes
    # お知らせ通知の購読 (capsicum#477 / capsicum-relay#14)。
    class AnnouncementSubscriptions < BaseApp
      post '/announcement_subscriptions' do
        authenticate!
        require_fields!('push_token', 'server', 'account')

        # push_token は subscriptions テーブルに存在しなければ FK 制約で失敗する。
        # 事前に存在確認して 404 を返す方が capsicum 側のエラーハンドリングが
        # 簡潔になる。
        parent = settings.database.find_by_push_token(json_body['push_token'])
        halt 404, {error: 'Unknown push token'}.to_json unless parent

        sub = settings.database.register_announcement_subscription(
          push_token: json_body['push_token'],
          server: json_body['server'],
          account: json_body['account'],
        )

        # account は既に user@host 形式なので server は付けない（@host が二重に
        # 出るのを避ける）。push 登録ログ (handle_push_*) と表記を揃える。
        settings.logger.info("Registered announcement: #{sub['account']} (#{sub['server']})")
        status 201
        sub.to_json
      end

      delete '/announcement_subscriptions/:id' do
        authenticate!

        sub = settings.database.unregister_announcement_subscription(params[:id].to_i)
        halt 404, {error: 'Not found'}.to_json unless sub

        settings.logger.info(
          "Unregistered announcement: #{sub['account']}@#{sub['server']}",
        )
        sub.to_json
      end

      # push_token 単位の一覧。capsicum が「relay 側にまだ購読が生きているか」を
      # 確認するのに使う。
      get '/announcement_subscriptions/:push_token' do
        authenticate!

        subs = settings.database.find_announcement_subscriptions_by_push_token(
          params[:push_token],
        )
        {subscriptions: subs}.to_json
      end
    end
  end
end
