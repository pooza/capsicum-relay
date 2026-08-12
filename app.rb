require 'sinatra/base'
require 'json'
require 'logger'
require 'yaml'
require_relative 'lib/relay/database'
require_relative 'lib/relay/apns_client'
require_relative 'lib/relay/fcm_client'
require_relative 'lib/relay/wns_client'
require_relative 'lib/relay/announcement_worker'
require_relative 'lib/relay/push_dedup'
require_relative 'lib/relay/push_helpers'
require_relative 'lib/relay/sentry_setup'

Relay::SentrySetup.init!

module Relay
  # 全 route を抱える単一 Sinatra クラス。push 送信・結果ハンドリング系の helper は
  # Relay::PushHelpers へ切り出し済み (#27)。残るのは route 定義と authenticate! /
  # json_body。helper 抽出後も route 本体だけで 130 行を超える（register /
  # announcement_subscriptions / supporters / push の CRUD 群）ため ClassLength は
  # 引き続き inline で許容する。route を別 Sinatra クラス / extension へ割るのが筋
  # だが、request テストの土台が無く回帰を検知できない（Database の migration 抽出
  # を見送ったのと同じ理由・#27 スコープ外）。土台が入ってから別 issue で。
  class App < Sinatra::Base # rubocop:disable Metrics/ClassLength
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

      if settings.config.dig('wns', 'package_sid')
        set :wns, Relay::WnsClient.new(settings.config, logger: settings.logger)
      end

      # 重複 push 抑止 (capsicum#692 / #16)。窓は ENV で調整可能、既定 1000ms。
      # 観測された重複バーストの広がりは <500ms なので余裕を持たせつつ、別通知
      # の誤マージを抑えるため過大にしない。0 以下なら無効化。
      dedup_window = Integer(ENV.fetch('PUSH_DEDUP_WINDOW_MS', 1000))
      set :push_dedup,
        (dedup_window.positive? ? Relay::PushDedup.new(window_ms: dedup_window) : nil)

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

    # push 送信・結果ハンドリング系（build_push_payload / dispatch_push /
    # handle_push_* 等）は Relay::PushHelpers へ切り出した (#27)。
    helpers Relay::PushHelpers

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
    end

    # Health check
    get '/health' do
      {
        status: 'ok',
        subscriptions: settings.database.count,
        announcement_subscriptions: settings.database.announcement_subscription_count,
        supporters: settings.database.supporter_count,
      }.to_json
    end

    # Register device token
    post '/register' do
      authenticate!

      required = ['token', 'device_type', 'account', 'server']
      missing = required.select {|k| json_body[k].nil? || json_body[k].empty?}
      halt 400, {error: "Missing fields: #{missing.join(', ')}"}.to_json unless missing.empty?

      unless ['ios', 'android', 'macos', 'windows'].include?(json_body['device_type'])
        halt 400, {error: 'device_type must be ios, android, macos or windows'}.to_json
      end

      # windows の token は WNS Channel URI。任意ホストを保存すると /push で
      # そこへ Bearer + payload 付き POST をさせられる (SSRF) ため、入口で WNS
      # ホストに限定する (#21 / capsicum#474 レビュー)。
      if json_body['device_type'] == 'windows' &&
          !Relay::WnsClient.valid_channel_uri?(json_body['token'])
        halt 400, {error: 'token must be a WNS channel URI (*.notify.windows.com)'}.to_json
      end

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

      # account は既に user@host 形式なので server は付けない（@host が二重に
      # 出るのを避ける）。push 登録ログ (handle_push_*) と表記を揃える。
      settings.logger.info("Registered announcement: #{sub['account']} (#{sub['server']})")
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

    # Record a supporter tip (capsicum#596 / #18)。(account, server) 単位の
    # upsert。tipped_at はローカル既存レコードの汲み上げ（バックフィル）用で、
    # 省略時・解釈不能時は現在時刻。
    post '/supporters/tip' do
      authenticate!

      required = ['account', 'server']
      missing = required.select {|k| json_body[k].nil? || json_body[k].empty?}
      halt 400, {error: "Missing fields: #{missing.join(', ')}"}.to_json unless missing.empty?

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

    # Fetch supporter status (capsicum#596 / #18)
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

      # 上流の孤児購読蓄積による重複 push を抑止 (capsicum#692 / #16)。
      # body を読まずに長さを得るため Content-Length を使う（build_push_payload
      # の request.body.read と二重読みにならない）。
      if settings.push_dedup&.duplicate?(
        params[:push_token],
        topic: request.env['HTTP_TOPIC'],
        length: request.content_length,
      )
        settings.logger.info(
          "Push deduped (#{sub['device_type']}): #{sub['account']}",
        )
        # 上流には配信成功として返す（4xx/5xx だと retry / subscription destroy
        # を誘発しうるため）。
        return {status: 'deduped'}.to_json
      end

      payload = build_push_payload(sub)
      result = dispatch_push(sub, payload)
      handle_push_result(sub, result)
    end
  end
end
