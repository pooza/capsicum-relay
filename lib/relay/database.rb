require 'securerandom'
require 'sqlite3'

module Relay
  class Database
    DB_PATH = File.expand_path('../../db/relay.sqlite3', __dir__)

    def initialize
      @db = SQLite3::Database.new(DB_PATH)
      @db.results_as_hash = true
      @db.execute('PRAGMA journal_mode=WAL')
      @db.execute('PRAGMA foreign_keys=ON')
      migrate!
    end

    # Subscription は (token, account, server) 単位で 1 行。同一端末に複数
    # アカウントを登録した場合は各アカウントに独立した row と push_token が
    # 割り当てられる。push_token 生成は新規 INSERT 時のみで、既存行の再登録
    # では push_token を維持する（Mastodon / Misskey 側の subscription endpoint
    # との整合を保つため）。
    def register(token:, device_type:, account:, server:)
      push_token = SecureRandom.hex(32)
      @db.execute(<<~SQL, [token, push_token, device_type, account, server])
        INSERT INTO subscriptions (token, push_token, device_type, account, server, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(token, account, server) DO UPDATE SET
          device_type = excluded.device_type,
          updated_at = datetime('now')
      SQL
      find_by_composite(token, account, server)
    end

    def unregister(id)
      sub = find(id)
      return nil unless sub

      @db.execute('DELETE FROM subscriptions WHERE id = ?', [id])
      sub
    end

    def find(id)
      @db.execute('SELECT * FROM subscriptions WHERE id = ?', [id]).first
    end

    def find_by_composite(token, account, server)
      @db.execute(
        'SELECT * FROM subscriptions WHERE token = ? AND account = ? AND server = ?',
        [token, account, server]
      ).first
    end

    def find_by_push_token(push_token)
      @db.execute('SELECT * FROM subscriptions WHERE push_token = ?', [push_token]).first
    end

    def update_push_token(id, push_token)
      @db.execute(<<~SQL, [push_token, id])
        UPDATE subscriptions SET push_token = ?, updated_at = datetime('now') WHERE id = ?
      SQL
    end

    def count
      @db.get_first_value('SELECT COUNT(*) FROM subscriptions')
    end

    private

    def migrate!
      existing = @db.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'subscriptions'"
      ).first

      if existing.nil?
        create_subscriptions_table!
      elsif !existing['sql'].include?('UNIQUE(token, account, server)')
        # 旧スキーマ（UNIQUE(token) 単独）からの移行。1 デバイス = 1 行の
        # 前提が崩れて N アカウント対応できないため、subscription-scoped に
        # 組み替える。pooza/capsicum-relay#3。
        migrate_to_subscription_scoped!
      end

      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_subscriptions_push_token
        ON subscriptions(push_token)
      SQL
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_subscriptions_token
        ON subscriptions(token)
      SQL
    end

    def create_subscriptions_table!
      @db.execute(<<~SQL)
        CREATE TABLE subscriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          token TEXT NOT NULL,
          push_token TEXT NOT NULL UNIQUE,
          device_type TEXT NOT NULL CHECK(device_type IN ('ios', 'android')),
          account TEXT NOT NULL,
          server TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(token, account, server)
        )
      SQL
    end

    def migrate_to_subscription_scoped!
      @db.transaction do
        @db.execute('ALTER TABLE subscriptions RENAME TO subscriptions_old')
        create_subscriptions_table!
        # 既存行は (device, account, server) のユニーク組（現スキーマ上
        # token UNIQUE なので 1:1 でコピー可能）。push_token は NULL 不許容に
        # 変わるため、万一 NULL のものがあれば埋める（運用上は 0 件想定）。
        @db.execute(<<~SQL)
          INSERT INTO subscriptions
            (id, token, push_token, device_type, account, server, created_at, updated_at)
          SELECT id, token,
                 COALESCE(push_token, lower(hex(randomblob(32)))),
                 device_type, account, server, created_at, updated_at
          FROM subscriptions_old
        SQL
        @db.execute('DROP TABLE subscriptions_old')
      end
    end
  end
end
