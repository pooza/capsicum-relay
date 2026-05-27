require 'sentry-ruby'

module Relay
  # Sentry 初期化。SENTRY_DSN が未設定なら no-op (development 等で誤投稿を避ける)。
  # capsicum-relay#10。
  module SentrySetup
    def self.init!
      dsn = ENV.fetch('SENTRY_DSN', nil)
      return unless dsn

      Sentry.init do |config|
        config.dsn = dsn
        config.environment = ENV.fetch('RACK_ENV', 'development')
        config.release = detect_release
        config.breadcrumbs_logger = [:sentry_logger]
        # request body は Web Push の暗号化ペイロードで意味がない上、token を含む
        # ことがあるため Sentry には送らない。Phase E (scrubbing) でさらに固める。
        config.send_default_pii = false
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
  end
end
