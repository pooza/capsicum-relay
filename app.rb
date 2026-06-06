require 'sinatra/base'
require 'json'
require 'logger'
require 'yaml'
require_relative 'lib/relay/database'
require_relative 'lib/relay/apns_client'
require_relative 'lib/relay/fcm_client'
require_relative 'lib/relay/announcement_worker'
require_relative 'lib/relay/sentry_setup'

Relay::SentrySetup.init!

module Relay
  class App < Sinatra::Base
    CONFIG_PATH = File.expand_path('config/settings.yml', __dir__)

    use Sentry::Rack::CaptureExceptions if Relay::SentrySetup.enabled?

    configure do
      set :config, YAML.load_file(CONFIG_PATH)
      set :database, Relay::Database.new
      set :logger, Logger.new($stdout)

      if settings.config.dig('apns', 'key_path')
        set :apns, Relay::ApnsClient.new(settings.config, logger: settings.logger)
      end
      set :fcm, Relay::FcmClient.new(settings.config) if settings.config.dig('fcm', 'project_id')

      # capsicum-relay#14 Phase 2: announcement polling worker。
      # interval が 0 / negative なら無効化 (テスト時等)。
      interval = settings.config.dig('announcement', 'poll_interval')
      if interval.nil? || interval.to_i.positive?
        set :announcement_worker, Relay::AnnouncementWorker.new(
          database: settings.database,
          logger: settings.logger,
          apns: (settings.respond_to?(:apns) ? settings.apns : nil),
          fcm: (settings.respond_to?(:fcm) ? settings.fcm : nil),
          interval: interval&.to_i || Relay::AnnouncementWorker::DEFAULT_INTERVAL,
        )
        settings.announcement_worker.start!
      end
    end

    before do
      content_type :json
    end

    helpers do
      def authenticate!
        secret = settings.config['shared_secret']
        provided = request.env['HTTP_X_RELAY_SECRET']
        halt 401, {error: 'Unauthorized'}.to_json unless provided == secret
      end

      def json_body
        @json_body ||= JSON.parse(request.body.read)
      rescue JSON::ParserError
        halt 400, {error: 'Invalid JSON'}.to_json
      end

      def build_push_payload(sub)
        payload = {
          'body' => Base64.strict_encode64(request.body.read),
          'encoding' => request.env['HTTP_CONTENT_ENCODING'].to_s,
          'server' => sub['server'],
          'account' => sub['account'],
        }
        # aes128gcm は body 先頭に salt / sender public key が埋まるので body と
        # encoding で足りるが、レガシー aesgcm は Crypto-Key / Encryption ヘッダに
        # 入るため、存在すれば転送する（旧 Mastodon / 一部 Misskey 対応）。
        crypto_key = request.env['HTTP_CRYPTO_KEY']
        encryption_header = request.env['HTTP_ENCRYPTION']
        payload['crypto_key'] = crypto_key if crypto_key
        payload['encryption'] = encryption_header if encryption_header
        return payload
      end

      def dispatch_push(sub, payload)
        case sub['device_type']
        when 'ios'
          halt 503, {error: 'APNs not configured'}.to_json unless settings.respond_to?(:apns)
          return settings.apns.push(device_token: sub['token'], payload: payload)
        when 'android'
          halt 503, {error: 'FCM not configured'}.to_json unless settings.respond_to?(:fcm)
          return settings.fcm.push(device_token: sub['token'], payload: payload)
        when 'macos'
          # macOS は iOS と同一 Bundle ID + 同一 APNs Auth Key で動くため
          # iOS と同じ APNs クライアントに流す (capsicum#468)。
          halt 503, {error: 'APNs not configured'}.to_json unless settings.respond_to?(:apns)
          return settings.apns.push(device_token: sub['token'], payload: payload)
        end
      end

      def log_push_received(sub)
        # 各サーバーがどの暗号化形式で送ってくるかを diagnose できるよう、
        # Content-Encoding と関連ヘッダの有無をログに残す (#5)。機密情報は
        # 含まないため常時出力。capsicum 側の復号 (#336) 検証時に役立つ。
        encoding = request.env['HTTP_CONTENT_ENCODING'].to_s
        crypto_key = request.env['HTTP_CRYPTO_KEY'] ? '+ck' : ''
        encryption = request.env['HTTP_ENCRYPTION'] ? '+enc' : ''
        settings.logger.info(
          "Received push: #{sub['account']} (#{sub['device_type']}," \
            " encoding=#{encoding.inspect}#{crypto_key}#{encryption})",
        )
      end

      def handle_push_result(sub, result)
        return handle_push_delivered(sub) if result[:success]
        return handle_push_oversized(sub, result) if result[:oversized]
        return handle_push_gone(sub, result) if result[:permanent]
        return handle_push_failed(sub, result)
      end

      # Sentry に載せる push 失敗コンテキスト。token は部分マスクし、生のレスポンス
      # body（FCM のエラー JSON 等）は status / reason に絞って送る (#10 Phase B/E)。
      def push_context(sub, result)
        {
          device_type: sub['device_type'],
          account: sub['account'],
          server: sub['server'],
          token: Relay::SentrySetup.mask_token(sub['token']),
          status: result[:status],
          reason: result[:reason],
        }.compact
      end

      def handle_push_delivered(sub)
        settings.logger.info("Pushed to #{sub['device_type']}: #{sub['account']}")
        return {status: 'delivered'}.to_json
      end

      def handle_push_gone(sub, result)
        # Device token が無効化された（UNREGISTERED / BadDeviceToken 等）。
        # Mastodon には 410 を返して subscription を destroy してもらい、
        # relay 側の行も掃除する。
        settings.database.unregister(sub['id'])
        reason = result[:reason] || result[:status]
        settings.logger.info("Subscription gone: #{sub['account']} (#{reason})")
        status 410
        return {status: 'gone', detail: result}.to_json
      end

      def handle_push_oversized(sub, result)
        # FCM (4KB) / APNs (4KB) のペイロード上限を超えた個別メッセージ。
        # subscription は健全なので unregister せず、Mastodon にも 413 を
        # 返してこの 1 通だけドロップさせる。permanent: false のままだと
        # Mastodon が retry を続けてログを汚すため、ここで明示的に止める (#9)。
        settings.logger.warn(
          "Push oversized (subscription kept): #{sub['account']}" \
            " (#{sub['device_type']}): #{result}",
        )
        # 健全な subscription を残したまま 1 通だけドロップする想定挙動だが、
        # 多発は送信側のペイロード設計問題を示すので warning として件数観測する
        # (#10 Phase B、#9 の後継観測)。
        Relay::SentrySetup.capture_message(
          "Push oversized dropped (#{sub['device_type']})",
          level: :warning,
          context: {push: push_context(sub, result)},
        )
        status 413
        return {status: 'oversized', detail: result}.to_json
      end

      def handle_push_failed(sub, result)
        settings.logger.error("Push failed: #{result}")
        # 一過性でない送信失敗（APNs / FCM の 5xx 等）。低頻度・高インパクトなので
        # journalctl 任せにせず Sentry で alert 駆動にする (#10 Phase B、#8 の後継観測)。
        Relay::SentrySetup.capture_message(
          "Push delivery failed (#{sub['device_type']})",
          level: :error,
          context: {push: push_context(sub, result)},
        )
        status 502
        return {status: 'failed', detail: result}.to_json
      end
    end

    # Health check
    get '/health' do
      {
        status: 'ok',
        subscriptions: settings.database.count,
        announcement_subscriptions: settings.database.announcement_subscription_count,
      }.to_json
    end

    # Register device token
    post '/register' do
      authenticate!

      required = ['token', 'device_type', 'account', 'server']
      missing = required.select {|k| json_body[k].nil? || json_body[k].empty?}
      halt 400, {error: "Missing fields: #{missing.join(', ')}"}.to_json unless missing.empty?

      unless ['ios', 'android', 'macos'].include?(json_body['device_type'])
        halt 400, {error: 'device_type must be ios, android or macos'}.to_json
      end

      sub = settings.database.register(
        token: json_body['token'],
        device_type: json_body['device_type'],
        account: json_body['account'],
        server: json_body['server'],
      )

      settings.logger.info("Registered: #{sub['account']} (#{sub['device_type']})")
      status 201
      sub.to_json
    end

    # Unregister
    delete '/register/:id' do
      authenticate!

      sub = settings.database.unregister(params[:id].to_i)
      halt 404, {error: 'Not found'}.to_json unless sub

      settings.logger.info("Unregistered: #{sub['account']}")
      sub.to_json
    end

    # Register announcement push subscription (capsicum#477 / capsicum-relay#14)
    post '/announcement_subscriptions' do
      authenticate!

      required = ['push_token', 'server', 'account']
      missing = required.select {|k| json_body[k].nil? || json_body[k].empty?}
      halt 400, {error: "Missing fields: #{missing.join(', ')}"}.to_json unless missing.empty?

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

      settings.logger.info(
        "Registered announcement: #{sub['account']}@#{sub['server']}",
      )
      status 201
      sub.to_json
    end

    # Unregister announcement push subscription
    delete '/announcement_subscriptions/:id' do
      authenticate!

      sub = settings.database.unregister_announcement_subscription(params[:id].to_i)
      halt 404, {error: 'Not found'}.to_json unless sub

      settings.logger.info(
        "Unregistered announcement: #{sub['account']}@#{sub['server']}",
      )
      sub.to_json
    end

    # List announcement push subscriptions for a push token (state check)
    get '/announcement_subscriptions/:push_token' do
      authenticate!

      subs = settings.database.find_announcement_subscriptions_by_push_token(
        params[:push_token],
      )
      {subscriptions: subs}.to_json
    end

    # Receive Web Push from Mastodon / Misskey
    post '/push/:push_token' do
      sub = settings.database.find_by_push_token(params[:push_token])
      # Mastodon は 410 Gone で subscription を自動 destroy するため、
      # 見つからない push_token は stale と見なして 410 で返す（404 だと
      # Mastodon 側に古い subscription が残り続ける）。
      unless sub
        # それ自体はエラーではない（stale subscription の自然な掃除）。同一
        # リクエスト内で別の例外が捕捉された際の文脈として breadcrumb を残す
        # に留める (#10 Phase D)。件数そのものの可視化は metrics (#2) 側で扱う。
        Relay::SentrySetup.breadcrumb(
          'Push for unknown token (410)',
          category: 'push',
          data: {push_token: Relay::SentrySetup.mask_token(params[:push_token])},
        )
        halt 410, {error: 'Unknown push token'}.to_json
      end

      log_push_received(sub)
      payload = build_push_payload(sub)
      result = dispatch_push(sub, payload)
      handle_push_result(sub, result)
    end
  end
end
