require 'json'
require 'logger'
require 'securerandom'
require 'sinatra/base'
require 'yaml'
require_relative 'announcement_worker'
require_relative 'apns_client'
require_relative 'database'
require_relative 'fcm_client'
require_relative 'metrics'
require_relative 'push_dedup'
require_relative 'push_helpers'
require_relative 'sentry_setup'
require_relative 'structured_log'
require_relative 'wns_client'

module Relay
  # 全 Sinatra アプリの土台 (#34)。設定・DB・push クライアント・共通 helper を
  # ここ 1 か所で組み立てる。
  #
  # ⚠ **route はここに書かない。** route 群は `Relay::Routes::*` に分かれており、
  # いずれもこのクラスを継承して [Relay::App] から `use` で連ねられる。Sinatra の
  # settings はクラス継承で引き継がれるので、`settings.database` などは各 route
  # クラスからそのまま見える（DB も push クライアントも**実体は 1 つ**）。
  #
  # `configure` はクラス定義時に 1 度だけ走る。サブクラス定義では再実行されない。
  class BaseApp < Sinatra::Base
    DEFAULT_CONFIG_PATH = File.expand_path('../../config/settings.yml', __dir__)

    # 読み込む設定ファイル。`RELAY_CONFIG_PATH` で差し替えられる (#34)。
    # request テストは本番の秘密情報を持たないので fixture を指して起動する。
    def self.config_path
      return ENV.fetch('RELAY_CONFIG_PATH', DEFAULT_CONFIG_PATH)
    end

    # 開く DB。`RELAY_DB_PATH` で差し替えられる (#34)。
    #
    # ⚠ **env を読むのはここだけ。** Relay::Database 側で読むと、どのテストが
    # 先に require したかで本番 DB を掴む形になりうる。
    def self.database_path
      return ENV.fetch('RELAY_DB_PATH', Relay::Database::DB_PATH)
    end

    configure do
      set :config, YAML.load_file(config_path)
      set :database, Relay::Database.new(path: database_path)
      # 1 行 = 1 JSON。人間向けの msg も同じ行に残す (#2・StructuredLog 参照)。
      set :logger, Logger.new($stdout, formatter: Relay::StructuredLog::FORMATTER)
      set :metrics, Relay::Metrics.new

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
      start_request!
    end

    # 応答に request_id を返す。capsicum 側の Sentry breadcrumb と journald を
    # 突き合わせるための取っ手 (#2)。⚠ **middleware として連なった route クラスの
    # after も走る**ので、既に付いていれば上書きしない。
    after do
      headers['X-Request-Id'] = request_id
    end

    # push 送信・結果ハンドリング系（build_push_payload / dispatch_push /
    # handle_push_* 等）は Relay::PushHelpers へ切り出してある (#27)。
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

      # 必須項目の検査。空文字は「送っていない」と同じ扱い。
      def require_fields!(*names)
        missing = names.select {|k| json_body[k].nil? || json_body[k].empty?}
        return if missing.empty?

        halt 400, {error: "Missing fields: #{missing.join(', ')}"}.to_json
      end

      # request_id と開始時刻を env に置く (#2)。
      #
      # ⚠ **route クラスを middleware として連ねているので before が何度も走る**
      # （一致しない route クラスも before を回してから forward する）。既に
      # 置いてあれば触らない。
      #
      # 現状ログを書くのは一致した route だけなので、これが無くても出力される
      # id は揃う。それでも先に置くのは 2 点のため:
      # - `latency_ms` が**チェーン全体**を測る（毎回上書きすると、最後の
      #   middleware から route までの区間しか測らなくなる）
      # - Sentry の scope へ同じ tag を連鎖のぶん何度も投げない
      def start_request!
        return if request.env['relay.request_id']

        # 上流 (nginx) が採番していればそれに乗る。無ければここで採る。
        id = request.env['HTTP_X_REQUEST_ID'].to_s
        id = SecureRandom.uuid if id.empty?
        request.env['relay.request_id'] = id
        request.env['relay.started_at'] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Relay::SentrySetup.tag_request(id)
      end

      def request_id
        return request.env['relay.request_id']
      end

      def latency_ms
        started_at = request.env['relay.started_at']
        return nil unless started_at

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        return (elapsed * 1000).round
      end

      # 構造化ログの入口 (#2)。`msg` は人間向けの 1 行で、grep 手順を壊さないため
      # 従来と同じ文言を渡す。それ以外は jq で集計するためのフィールド。
      def log_event(event, msg:, level: :info, **fields)
        settings.logger.public_send(
          level,
          {event: event, request_id: request_id, msg: msg}.merge(fields),
        )
      end

      def metrics
        return settings.metrics
      end
    end
  end
end
