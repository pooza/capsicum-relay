require_relative 'test_helper'
require 'fileutils'
require 'logger'
require 'sqlite3'
require 'tmpdir'
require 'lib/relay/database'

# announcement_subscriptions の FK 修復 (capsicum#468 リグレッションの自己修復)。
# 本番 DB に対して破壊的に走る箇所なので、修復で何が直り何が保たれるかを固定する。
class DatabaseTest < Minitest::Test
  # capsicum#468 を踏んだ環境のスキーマ。subscriptions の組み替えを
  # legacy_alter_table 未指定でやった結果、FK が実在しない subscriptions_old を
  # 指したまま残っている。
  BROKEN_SCHEMA = <<~SQL.freeze
    CREATE TABLE announcement_subscriptions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      push_token TEXT NOT NULL,
      server TEXT NOT NULL,
      account TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(push_token, server, account),
      FOREIGN KEY (push_token) REFERENCES subscriptions_old(push_token) ON DELETE CASCADE
    )
  SQL

  def setup
    @dir = Dir.mktmpdir('relay-database-test')
    @original_db_path = Relay::Database::DB_PATH
    swap_db_path(File.join(@dir, 'relay.sqlite3'))
  end

  def teardown
    swap_db_path(@original_db_path)
    FileUtils.remove_entry(@dir)
  end

  # --- 新規作成 ---------------------------------------------------------------

  def test_fresh_schema_points_the_foreign_key_at_subscriptions
    open_database
    fk = foreign_keys.first

    assert_equal('subscriptions', fk['table'])
    assert_equal('push_token', fk['from'])
    assert_equal('push_token', fk['to'])
    assert_equal('CASCADE', fk['on_delete'])
  end

  # FK が壊れていると効かなくなる実害そのもの。subscription を消したら
  # お知らせ購読も道連れになること。
  def test_deleting_a_subscription_cascades_to_its_announcement_subscription
    db = open_database
    sub = register_with_announcement(db)
    db.unregister(sub['id'])

    assert_empty(db.find_announcement_subscriptions_by_push_token(sub['push_token']))
  end

  # --- 修復 -------------------------------------------------------------------

  def test_broken_foreign_key_is_rewritten_to_subscriptions
    register_with_announcement(open_database)
    break_foreign_key!

    open_database # migrate! の中で修復が走る

    assert_equal('subscriptions', foreign_keys.first['table'])
  end

  def test_repair_keeps_existing_rows
    sub = register_with_announcement(open_database)
    before = announcement_rows
    break_foreign_key!

    db = open_database

    assert_equal(before, announcement_rows)
    assert_equal(1, db.find_announcement_subscriptions_by_push_token(sub['push_token']).size)
  end

  def test_repair_restores_the_cascade
    db = open_database
    sub = register_with_announcement(db)
    break_foreign_key!

    db = open_database
    db.unregister(sub['id'])

    assert_empty(db.find_announcement_subscriptions_by_push_token(sub['push_token']))
  end

  def test_repair_leaves_no_work_table_behind
    register_with_announcement(open_database)
    break_foreign_key!

    open_database

    assert_empty(table_names.grep(/_broken\z/))
  end

  def test_repair_recreates_the_indexes
    register_with_announcement(open_database)
    break_foreign_key!

    open_database

    assert_includes(index_names, 'idx_announcement_subscriptions_server')
    assert_includes(index_names, 'idx_announcement_subscriptions_push_token')
  end

  # 壊れていない DB を開き直しても組み替えが走らないこと（冪等）。
  def test_repair_is_a_no_op_when_the_foreign_key_is_already_correct
    register_with_announcement(open_database)
    before = table_schema

    open_database

    assert_equal(before, table_schema)
  end

  private

  def swap_db_path(path)
    Relay::Database.send(:remove_const, :DB_PATH)
    Relay::Database.const_set(:DB_PATH, path)
  end

  def open_database
    return Relay::Database.new(logger: Logger.new(File::NULL))
  end

  def register_with_announcement(db)
    sub = db.register(token: 'tok', device_type: 'ios', account: 'alice', server: 'example.com')
    db.register_announcement_subscription(
      push_token: sub['push_token'],
      server: 'example.com',
      account: 'alice',
    )
    return sub
  end

  # 行はそのままに、テーブル定義だけ capsicum#468 相当へ差し替える。
  def break_foreign_key!
    raw do |db|
      rows = db.execute('SELECT * FROM announcement_subscriptions')
      db.execute('PRAGMA foreign_keys=OFF')
      db.execute('DROP TABLE announcement_subscriptions')
      db.execute(BROKEN_SCHEMA)
      rows.each {|row| insert_announcement_row(db, row)}
    end
  end

  def insert_announcement_row(db, row)
    columns = ['id', 'push_token', 'server', 'account', 'created_at', 'updated_at']
    db.execute(
      "INSERT INTO announcement_subscriptions (#{columns.join(', ')}) VALUES (?, ?, ?, ?, ?, ?)",
      row.values_at(*columns),
    )
  end

  def raw
    db = SQLite3::Database.new(Relay::Database::DB_PATH)
    db.results_as_hash = true
    return yield(db)
  ensure
    db&.close
  end

  def foreign_keys
    return raw {|db| db.execute('PRAGMA foreign_key_list(announcement_subscriptions)')}
  end

  def index_names
    return raw {|db| db.execute('PRAGMA index_list(announcement_subscriptions)')}.map {|row| row['name']}
  end

  def table_names
    return raw {|db| db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}.map {|row| row['name']}
  end

  def table_schema
    sql = "SELECT sql FROM sqlite_master WHERE name = 'announcement_subscriptions'"
    return raw {|db| db.execute(sql)}.first['sql']
  end

  def announcement_rows
    return raw {|db| db.execute('SELECT * FROM announcement_subscriptions ORDER BY id')}
  end
end
