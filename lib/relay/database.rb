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
      return find_by_composite(token, account, server)
    end

    def unregister(id)
      sub = find(id)
      return nil unless sub

      @db.execute('DELETE FROM subscriptions WHERE id = ?', [id])
      return sub
    end

    def find(id)
      return @db.execute('SELECT * FROM subscriptions WHERE id = ?', [id]).first
    end

    def find_by_composite(token, account, server)
      return @db.execute(
        'SELECT * FROM subscriptions WHERE token = ? AND account = ? AND server = ?',
        [token, account, server],
      ).first
    end

    def find_by_push_token(push_token)
      return @db.execute('SELECT * FROM subscriptions WHERE push_token = ?', [push_token]).first
    end

    def update_push_token(id, push_token)
      return @db.execute(<<~SQL, [push_token, id])
        UPDATE subscriptions SET push_token = ?, updated_at = datetime('now') WHERE id = ?
      SQL
    end

    def count
      return @db.get_first_value('SELECT COUNT(*) FROM subscriptions')
    end

    # お知らせ通知 (announcement push) の subscription 管理。capsicum#477 /
    # capsicum-relay#14。subscriptions と外部キーで紐付き、subscription 解除
    # 時にカスケード削除される。
    def register_announcement_subscription(push_token:, server:, account:)
      @db.execute(<<~SQL, [push_token, server, account])
        INSERT INTO announcement_subscriptions
          (push_token, server, account, created_at, updated_at)
        VALUES (?, ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(push_token, server, account) DO UPDATE SET
          updated_at = datetime('now')
      SQL
      return find_announcement_subscription_by_composite(push_token, server, account)
    end

    def unregister_announcement_subscription(id)
      sub = find_announcement_subscription(id)
      return nil unless sub

      @db.execute('DELETE FROM announcement_subscriptions WHERE id = ?', [id])
      return sub
    end

    def find_announcement_subscription(id)
      return @db.execute(
        'SELECT * FROM announcement_subscriptions WHERE id = ?', [id]
      ).first
    end

    def find_announcement_subscription_by_composite(push_token, server, account)
      return @db.execute(<<~SQL, [push_token, server, account]).first
        SELECT * FROM announcement_subscriptions
        WHERE push_token = ? AND server = ? AND account = ?
      SQL
    end

    def find_announcement_subscriptions_by_push_token(push_token)
      return @db.execute(
        'SELECT * FROM announcement_subscriptions WHERE push_token = ?',
        [push_token],
      )
    end

    def announcement_subscription_count
      return @db.get_first_value('SELECT COUNT(*) FROM announcement_subscriptions')
    end

    # announcement polling worker (capsicum-relay#14 Phase 2) 用。subscription が
    # 1 件でもある server のみ poll 対象にする。
    def announcement_servers
      return @db.execute(<<~SQL).map {|row| row['server']}
        SELECT DISTINCT server FROM announcement_subscriptions
      SQL
    end

    # server に紐づく subscription を、push 発火に必要な device_type / token と
    # 一緒に取得する (subscriptions を JOIN)。
    def announcement_subscriptions_for_server(server)
      return @db.execute(<<~SQL, [server])
        SELECT a.id AS announcement_subscription_id, a.server, a.account,
               s.id AS subscription_id, s.token, s.device_type, s.push_token
        FROM announcement_subscriptions a
        JOIN subscriptions s ON a.push_token = s.push_token
        WHERE a.server = ?
      SQL
    end

    def announcement_seen?(server, announcement_id)
      return @db.get_first_value(<<~SQL, [server, announcement_id.to_s]).to_i.positive?
        SELECT COUNT(*) FROM seen_announcements
        WHERE server = ? AND announcement_id = ?
      SQL
    end

    def mark_announcement_seen(server, announcement_id)
      @db.execute(<<~SQL, [server, announcement_id.to_s])
        INSERT OR IGNORE INTO seen_announcements (server, announcement_id, seen_at)
        VALUES (?, ?, datetime('now'))
      SQL
    end

    private

    def migrate!
      existing = @db.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'subscriptions'",
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

      create_announcement_tables!
    end

    def create_announcement_tables!
      create_announcement_subscriptions_table!
      create_seen_announcements_table!
    end

    def create_announcement_subscriptions_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS announcement_subscriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          push_token TEXT NOT NULL,
          server TEXT NOT NULL,
          account TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(push_token, server, account),
          FOREIGN KEY (push_token) REFERENCES subscriptions(push_token) ON DELETE CASCADE
        )
      SQL
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_announcement_subscriptions_server
        ON announcement_subscriptions(server)
      SQL
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_announcement_subscriptions_push_token
        ON announcement_subscriptions(push_token)
      SQL
    end

    def create_seen_announcements_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS seen_announcements (
          server TEXT NOT NULL,
          announcement_id TEXT NOT NULL,
          seen_at TEXT NOT NULL,
          PRIMARY KEY (server, announcement_id)
        )
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
