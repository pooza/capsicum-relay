require_relative 'lib/relay/base_app'
require_relative 'lib/relay/routes/announcement_subscriptions'
require_relative 'lib/relay/routes/health'
require_relative 'lib/relay/routes/push'
require_relative 'lib/relay/routes/register'
require_relative 'lib/relay/routes/supporters'
require_relative 'lib/relay/sentry_setup'

Relay::SentrySetup.init!

module Relay
  # 合成だけを担う入口 (#34)。設定・DB・helper は [Relay::BaseApp]、route は
  # `Relay::Routes::*` にある。
  #
  # route クラスは **Sinatra の middleware として連ねる**。Sinatra は route が
  # 一致しなければ次のアプリへ forward するので、`Rack::Cascade` と違って
  # 「route は一致したが `halt 404` した」ケースを次に流してしまうことがない
  # （DELETE /register/:id の 404 が別 route に食われる、といった事故を避ける）。
  #
  # 並び順に依存は無い（パスが重ならない）。読みやすさのためアルファベット順。
  class App < BaseApp
    use Sentry::Rack::CaptureExceptions if Relay::SentrySetup.enabled?

    use Routes::AnnouncementSubscriptions
    use Routes::Health
    use Routes::Push
    use Routes::Register
    use Routes::Supporters
  end
end
