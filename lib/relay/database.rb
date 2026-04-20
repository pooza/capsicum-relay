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

    def register(token:, device_type:, account:, server:)
      push_token = SecureRandom.hex(32)
      @db.execute(<<~SQL, [token, push_token, device_type, account, server])
        INSERT INTO subscriptions (token, push_token, device_type, account, server, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(token) DO UPDATE SET
          device_type = excluded.device_type,
          account = excluded.account,
          server = excluded.server,
          updated_at = datetime('now')
      SQL
      find_by_token(token)
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

    def find_by_token(token)
      @db.execute('SELECT * FROM subscriptions WHERE token = ?', [token]).first
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
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS subscriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          token TEXT NOT NULL UNIQUE,
          push_token TEXT,
          device_type TEXT NOT NULL CHECK(device_type IN ('ios', 'android')),
          account TEXT NOT NULL,
          server TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      SQL
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_subscriptions_push_token
        ON subscriptions(push_token)
      SQL
    end
  end
end
