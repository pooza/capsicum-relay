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
      # ⚠ **logger を先に作る。** Database / 各クライアントは construct 時の
      # logger を握るので、あとから set しても差し替わらない。順番を崩すと
      # 孤児 subscription の掃除 (Database#purge_legacy_rows 等) だけが素の
      # Logger で出て、「1 行 = 1 JSON」の約束が破れる (Codex P2 / PR #42)。
      # 1 行 = 1 JSON。人間向けの msg も同じ行に残す (#2・StructuredLog 参照)。
      set :logger, Logger.new($stdout, formatter: Relay::StructuredLog::FORMATTER)
      set :database, Relay::Database.new(path: database_path, logger: settings.logger)
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
        # ⚠ **push クライアントの配線は worker 側 (from_settings) が持つ** (#36
        # Phase 2)。ここに列挙していたときは、`deliver` に device_type を足しても
        # 渡し忘れれば「購読行はあるのに 1 通も届かない」形になり、例外にならない
        # ぶんテストにもログにも出なかった。
        set :announcement_worker, Relay::AnnouncementWorker.from_settings(
          settings,
          database: settings.database,
          logger: settings.logger,
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
      # 共有シークレットによる認証 (#47)。
      #
      # ⚠ **弾いたことを必ずログに残す。** 以前は無言で halt しており、
      # サーバー側から「リクエストが来ていない」と「来たが弾いた」を区別できな
      # かった。2026-08-18 に staging の journald が空なのを見て「クライアントが
      # 投げていない」と誤診している（実際は capsicum の debug ビルドが
      # `--dart-define=RELAY_SECRET` 無しでビルドされ、空の secret を送っていた。
      # pooza/capsicum#994）。原因はまったく別（向け先 / 資格情報）なので、
      # ここが無音だと切り分けが端末側の画面頼みになる。
      #
      # ⚠ **secret そのものは絶対に出さない。**残すのは `missing`（ヘッダが無い
      # / 空）か `mismatch`（値が違う）かの 2 値だけ。この区別に意味がある —
      # `missing` はビルド時に値を渡し忘れた形、`mismatch` は値が古い形で、
      # 対処が違う。
      def authenticate!
        secret = settings.config['shared_secret']
        provided = request.env['HTTP_X_RELAY_SECRET']
        return if provided == secret

        log_auth_rejected(provided)
        halt 401, {error: 'Unauthorized'}.to_json
      end

      def log_auth_rejected(provided)
        reason = provided.to_s.empty? ? 'missing' : 'mismatch'
        path = redacted_path
        log_event(
          'auth.rejected',
          level: :warn,
          msg: "Rejected unauthenticated request: #{path} (#{reason})",
          reason: reason,
          path: path,
          method: request.request_method,
        )
      end

      # ⚠ **`path_info` をそのまま残さない** (PR #48 の Codex P1)。
      # `/push/:push_token` と `/announcement_subscriptions/:push_token` は
      # **path 自体に capability secret が載る**。[Relay::StructuredLog.fingerprint]
      # が push_token を指紋にしているのと同じ理由で、ここも生では出せない。
      #
      # 先頭セグメントだけ残せば「どのエンドポイントが弾かれたか」という切り分けに
      # 要る情報は保てる。⚠ **allow-list ではなく既定で落とす形にするのが要点。**
      # route が増えたときに自動で安全側へ倒れる（`/supporters/tip` のように可変部が
      # 無い 2 段の route も畳まれるが、`method` で区別できる）。
      def redacted_path
        head = request.path_info.to_s.split('/')[1].to_s
        return '/' if head.empty?

        return request.path_info.to_s.count('/') > 1 ? "/#{head}/…" : "/#{head}"
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
