require 'sentry-ruby'

module Relay
  # Sentry 初期化と、計装コードから使う薄いヘルパ群。SENTRY_DSN が未設定なら
  # init! は no-op になり、各ヘルパも Sentry.initialized? を見て no-op になる
  # （development / test での誤投稿を避ける）。capsicum-relay#10。
  module SentrySetup
    # Sentry に送らないリクエストヘッダ。relay 共有シークレット・認可ヘッダと、
    # Web Push のレガシー暗号鍵ヘッダ。before_send で event から除去する
    # (#10 Phase E)。RequestInterface はヘッダ名をタイトルケース化するため
    # その表記で並べ、念のため downcase も併せて削る。
    SENSITIVE_HEADERS = ['X-Relay-Secret', 'Authorization', 'Crypto-Key', 'Encryption'].freeze

    def self.init!
      dsn = ENV.fetch('SENTRY_DSN', nil)
      return unless dsn

      Sentry.init do |config|
        config.dsn = dsn
        config.environment = ENV.fetch('RACK_ENV', 'development')
        config.release = detect_release
        config.breadcrumbs_logger = [:sentry_logger]
        # request body は Web Push の暗号化ペイロードで意味がない上、token を含む
        # ことがあるため Sentry には送らない。send_default_pii=false で IP / cookie
        # も抑止し、before_send でヘッダ / body をさらにスクラブする (#10 Phase E)。
        config.send_default_pii = false
        config.before_send = ->(event, _hint) {scrub_event(event)}
      end
    end

    def self.enabled?
      return Sentry.initialized?
    end

    def self.detect_release
      explicit = ENV.fetch('SENTRY_RELEASE', nil)
      return explicit if explicit

      sha = `git rev-parse HEAD 2>/dev/null`.strip
      return sha.empty? ? nil : sha
    end

    # device token / push token を部分マスクして Sentry に送る (#10 Phase E)。
    # 全値は送らない。短いトークンは情報量を出さないよう全マスクする。
    def self.mask_token(token)
      str = token.to_s
      return '(empty)' if str.empty?
      return '*' * str.length if str.length <= 12

      return "#{str[0, 6]}…#{str[-4, 4]}"
    end

    # 以下の capture 系 / breadcrumb は Sentry 未初期化時 (development / test) は
    # no-op。呼び出し側のガードをここに集約し、計装コードを簡潔に保つ。

    def self.capture_exception(error, context: {})
      return unless Sentry.initialized?

      Sentry.with_scope do |scope|
        context.each {|key, value| scope.set_context(key.to_s, value)}
        Sentry.capture_exception(error)
      end
    end

    def self.capture_message(message, level: :error, context: {})
      return unless Sentry.initialized?

      Sentry.with_scope do |scope|
        scope.set_level(level)
        context.each {|key, value| scope.set_context(key.to_s, value)}
        Sentry.capture_message(message)
      end
    end

    def self.breadcrumb(message, category:, data: {})
      return unless Sentry.initialized?

      Sentry.add_breadcrumb(
        Sentry::Breadcrumb.new(category: category, message: message, data: data),
      )
    end

    # Rack integration が拾うリクエストヘッダ / body から機密値を落とす。
    # request コンテキストを持たない event (worker 由来等) はそのまま通す。
    def self.scrub_event(event)
      request = event.respond_to?(:request) ? event.request : nil
      return event unless request

      headers = request.headers
      if headers.is_a?(Hash)
        SENSITIVE_HEADERS.each do |name|
          headers.delete(name)
          headers.delete(name.downcase)
        end
      end
      request.data = nil if request.respond_to?(:data=)
      return event
    end
  end
end
