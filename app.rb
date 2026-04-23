require 'sinatra/base'
require 'json'
require 'logger'
require 'yaml'
require_relative 'lib/relay/database'
require_relative 'lib/relay/apns_client'
require_relative 'lib/relay/fcm_client'

module Relay
  class App < Sinatra::Base
    CONFIG_PATH = File.expand_path('config/settings.yml', __dir__)

    configure do
      set :config, YAML.load_file(CONFIG_PATH)
      set :database, Relay::Database.new
      set :logger, Logger.new($stdout)

      if settings.config.dig('apns', 'key_path')
        set :apns, Relay::ApnsClient.new(settings.config)
      end
      if settings.config.dig('fcm', 'project_id')
        set :fcm, Relay::FcmClient.new(settings.config)
      end
    end

    before do
      content_type :json
    end

    helpers do
      def authenticate!
        secret = settings.config['shared_secret']
        provided = request.env['HTTP_X_RELAY_SECRET']
        halt 401, { error: 'Unauthorized' }.to_json unless provided == secret
      end

      def json_body
        @json_body ||= JSON.parse(request.body.read)
      rescue JSON::ParserError
        halt 400, { error: 'Invalid JSON' }.to_json
      end
    end

    # Health check
    get '/health' do
      {
        status: 'ok',
        subscriptions: settings.database.count,
      }.to_json
    end

    # Register device token
    post '/register' do
      authenticate!

      required = %w[token device_type account server]
      missing = required.select { |k| json_body[k].nil? || json_body[k].empty? }
      halt 400, { error: "Missing fields: #{missing.join(', ')}" }.to_json unless missing.empty?

      unless %w[ios android].include?(json_body['device_type'])
        halt 400, { error: 'device_type must be ios or android' }.to_json
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
      halt 404, { error: 'Not found' }.to_json unless sub

      settings.logger.info("Unregistered: #{sub['account']}")
      sub.to_json
    end

    # Receive Web Push from Mastodon / Misskey
    post '/push/:push_token' do
      sub = settings.database.find_by_push_token(params[:push_token])
      # Mastodon は 410 Gone で subscription を自動 destroy するため、
      # 見つからない push_token は stale と見なして 410 で返す（404 だと
      # Mastodon 側に古い subscription が残り続ける）。
      halt 410, { error: 'Unknown push token' }.to_json unless sub

      # Web Push ペイロードはそのまま転送（復号はクライアント側）。
      # aes128gcm (RFC 8291) は salt / sender public key が body 先頭に
      # 埋め込まれるため body と encoding だけで足りるが、レガシーの
      # aesgcm は Crypto-Key / Encryption ヘッダに salt / dh 公開鍵が入る
      # ため、両ヘッダも転送する（Misskey 一部フォークや旧 Mastodon 対応）。
      raw_body = request.body.read
      encoding = request.env['HTTP_CONTENT_ENCODING']
      crypto_key = request.env['HTTP_CRYPTO_KEY']
      encryption_header = request.env['HTTP_ENCRYPTION']

      payload = {
        'body' => Base64.strict_encode64(raw_body),
        'encoding' => encoding.to_s,
        'server' => sub['server'],
        'account' => sub['account'],
      }
      payload['crypto_key'] = crypto_key if crypto_key
      payload['encryption'] = encryption_header if encryption_header

      result = case sub['device_type']
               when 'ios'
                 halt 503, { error: 'APNs not configured' }.to_json unless settings.respond_to?(:apns)
                 settings.apns.push(device_token: sub['token'], payload: payload)
               when 'android'
                 halt 503, { error: 'FCM not configured' }.to_json unless settings.respond_to?(:fcm)
                 settings.fcm.push(device_token: sub['token'], payload: payload)
               end

      if result[:success]
        settings.logger.info("Pushed to #{sub['device_type']}: #{sub['account']}")
        { status: 'delivered' }.to_json
      elsif result[:permanent]
        # Device token が無効化された（UNREGISTERED / BadDeviceToken 等）。
        # Mastodon には 410 を返して subscription を destroy してもらい、
        # relay 側の行も掃除する。
        settings.database.unregister(sub['id'])
        settings.logger.info("Subscription gone: #{sub['account']} (#{result[:reason] || result[:status]})")
        status 410
        { status: 'gone', detail: result }.to_json
      else
        settings.logger.error("Push failed: #{result}")
        status 502
        { status: 'failed', detail: result }.to_json
      end
    end
  end
end
