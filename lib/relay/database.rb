require 'logger'
require 'securerandom'
require 'sqlite3'

module Relay
  class Database
    DB_PATH = File.expand_path('../../db/relay.sqlite3', __dir__)

    # テーブル組み替え (rebuild_with_all_rows!) でコピーする列。実際には旧テーブル
    # に実在するものだけに絞る。device_id (#15) は ALTER で後付けされるため、組み
    # 替えが走る時点で有る場合と無い場合があり、固定リストで書くとどちらかで壊れる
    # （無い列を SELECT すれば SQLException、有る列を落とせば device_id が黙って
    # 消えて dedup が失われる）。
    COPYABLE_SUBSCRIPTION_COLUMNS = [
      'id', 'token', 'push_token', 'device_type', 'account', 'server',
      'device_id', 'created_at', 'updated_at'
    ].freeze

    def initialize(logger: Logger.new($stdout))
      @logger = logger
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
    #
    # [device_id] はクライアントがインストール単位で持つ安定 ID (capsicum#932)。
    # 渡された場合は **(account, server, device_id) をキーに upsert** し、
    # トークンが更新されても行を増やさず token を差し替える。これがないと
    # 「push トークン更新 → 新しい行 → 旧行が孤児化 → 二重 push」が積み上がる
    # (#15)。渡されない（旧クライアント）場合は従来どおり token をキーにする。
    def register(token:, device_type:, account:, server:, device_id: nil)
      device_id = nil if device_id.to_s.empty?
      return register_by_token(token, device_type, account, server) unless device_id

      row = adoptable_row(token, account, server, device_id)
      return update_registration(row, token, device_type, device_id) if row

      insert_registration(token, device_type, account, server, device_id)
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

    # インストール単位の device_id で引く (#15)。(account, server, device_id) は
    # 部分 UNIQUE インデックスで一意。
    def find_by_device(account, server, device_id)
      return @db.execute(
        'SELECT * FROM subscriptions WHERE account = ? AND server = ? AND device_id = ?',
        [account, server, device_id],
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

    # サポーター状態 (capsicum#596 / #18)。(account, server) 単位で 1 行。
    # subscriptions とは独立（push 未登録の端末からも投げ銭は成立する）。
    # tip_count は複数端末の合算で、再送による多少の過大計上を許容する近似値。
    # バッジ判定は first_tipped_at の有無のみで行う。
    def record_supporter_tip(account:, server:, sku: nil, tipped_at: nil, count: 1)
      # tipped_at は ISO8601 を datetime() で正規化して保存する。
      # datetime('now') と同じ 'YYYY-MM-DD HH:MM:SS' 形式に揃えないと、
      # upsert の MIN() が文字列比較で破綻する。
      @db.execute(<<~SQL, [account, server, tipped_at, count, sku])
        INSERT INTO supporters
          (account, server, first_tipped_at, tip_count, last_sku, created_at, updated_at)
        VALUES (?, ?, COALESCE(datetime(?), datetime('now')), ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(account, server) DO UPDATE SET
          first_tipped_at = MIN(first_tipped_at, excluded.first_tipped_at),
          tip_count = tip_count + excluded.tip_count,
          last_sku = COALESCE(excluded.last_sku, last_sku),
          updated_at = datetime('now')
      SQL
      return find_supporter(account: account, server: server)
    end

    def find_supporter(account:, server:)
      return @db.execute(
        'SELECT * FROM supporters WHERE account = ? AND server = ?',
        [account, server],
      ).first
    end

    def supporter_count
      return @db.get_first_value('SELECT COUNT(*) FROM supporters')
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

    # device_id を送らない旧クライアント向けの従来経路。(token, account, server)
    # をキーにした upsert で、トークンが変われば別の行になる。
    def register_by_token(token, device_type, account, server)
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

    # device_id 付き register が上書きすべき既存行を決める。**この順序に意味が
    # ある**（どちらの制約にも触れずに済む唯一の順序）:
    #
    # 1. **今のトークンを持つ行**があればそれ。上流 (Mastodon / Misskey) が現に
    #    push している行なので、push_token を保ったまま device_id を埋める。
    #    トークンを書き換えないので UNIQUE(token, account, server) に触れない。
    #    同じ device_id を持つ別行があれば、それは同一インストールの古い孤児
    #    なので畳む（部分 UNIQUE インデックスを守るためにも必要）。
    # 2. なければ**同じ device_id の行**。これがトークン更新のケースで、行を
    #    増やさず token だけ差し替える。1 で外れている = その (token, account,
    #    server) を持つ行は無いので、やはり衝突しない。
    # 3. どちらも無ければ新規 INSERT（呼び出し側）。
    #
    # 1 と 2 が別の行を指すのは、トークンが一度離れて戻る場合だけで実運用では
    # 起きない（APNs / FCM トークンも WNS Channel URI も巻き戻らない）。部分
    # UNIQUE インデックスを違反させないための防御として畳んでおく。畳んだ行の
    # announcement_subscriptions は FK の CASCADE で一緒に消える。
    def adoptable_row(token, account, server, device_id)
      by_token = find_by_composite(token, account, server)
      by_device = find_by_device(account, server, device_id)
      return by_device unless by_token
      return by_token if by_device.nil? || by_token['id'] == by_device['id']

      @logger.info(
        "Collapsing orphaned subscription id=#{by_device['id']} into" \
          " id=#{by_token['id']} (#{account}@#{server})",
      )
      @db.execute('DELETE FROM subscriptions WHERE id = ?', [by_device['id']])
      return by_token
    end

    # push_token は維持する。上流に登録済みの endpoint (/push/{push_token}) が
    # 変わると、その購読が宙に浮いて再登録されるまで不達になるため。
    def update_registration(row, token, device_type, device_id)
      @db.execute(<<~SQL, [token, device_type, device_id, row['id']])
        UPDATE subscriptions
        SET token = ?, device_type = ?, device_id = ?, updated_at = datetime('now')
        WHERE id = ?
      SQL
      return find(row['id'])
    end

    def insert_registration(token, device_type, account, server, device_id)
      @db.execute(<<~SQL, [token, SecureRandom.hex(32), device_type, account, server, device_id])
        INSERT INTO subscriptions
          (token, push_token, device_type, account, server, device_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
      SQL
    end

    def migrate!
      existing = subscriptions_schema
      if existing.nil?
        create_subscriptions_table!
      else
        migrate_subscriptions!(existing)
      end

      create_subscriptions_indexes!
      create_announcement_tables!
      create_supporters_table!
    end

    def create_subscriptions_indexes!
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_subscriptions_push_token
        ON subscriptions(push_token)
      SQL
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_subscriptions_token
        ON subscriptions(token)
      SQL
      # device-id dedup の実質的な UNIQUE 制約 (#15)。SQLite はテーブル制約に
      # WHERE を書けないので部分インデックスで張る。device_id を送らない旧
      # クライアントの行は全て NULL で、NULL 同士は UNIQUE でも衝突しないが、
      # 「旧クライアントは対象外」という意図を明示するため WHERE を書く。
      @db.execute(<<~SQL)
        CREATE UNIQUE INDEX IF NOT EXISTS idx_subscriptions_device
        ON subscriptions(account, server, device_id)
        WHERE device_id IS NOT NULL
      SQL
    end

    def subscriptions_schema
      return @db.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'subscriptions'",
      ).first
    end

    # 既存 subscriptions テーブルへの段階的スキーマ移行。SQLite は UNIQUE / CHECK
    # の ALTER ができないため、各移行はテーブル組み替え (rebuild_subscriptions_table!)
    # で行う。各 migrate_* はスキーマを読み直してから走らせ、前段の組み替えが
    # 最新スキーマを生成済みなら二重実行しない。
    def migrate_subscriptions!(existing)
      unless existing['sql'].include?('UNIQUE(token, account, server)')
        # 旧スキーマ（UNIQUE(token) 単独）からの移行。1 デバイス = 1 行の
        # 前提が崩れて N アカウント対応できないため、subscription-scoped に
        # 組み替える。pooza/capsicum-relay#3。
        migrate_to_subscription_scoped!
      end
      # device_type CHECK の enum 追加 (#468 macos / #474 windows)。最新スキーマで
      # 作り直して全行コピー。前段が最新を生成済みならスキーマ判定で skip。
      rebuild_with_all_rows! unless subscriptions_schema['sql'].include?("'macos'")
      rebuild_with_all_rows! unless subscriptions_schema['sql'].include?("'windows'")
      # client 由来の安定 device-id (#15 / capsicum#932)。nullable な列の追加
      # だけなのでテーブル組み替えは要らない。既存行は NULL のまま残り、次回の
      # register で埋まる。
      return if subscriptions_schema['sql'].include?('device_id')
      @db.execute('ALTER TABLE subscriptions ADD COLUMN device_id TEXT')
    end

    # サポーター状態 (capsicum#596 / #18)。将来の有償リレー利用権
    # (capsicum#597) はこの account-keyed entitlement 行を課金判定に
    # 格上げして再利用する想定。
    def create_supporters_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS supporters (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          account TEXT NOT NULL,
          server TEXT NOT NULL,
          first_tipped_at TEXT NOT NULL,
          tip_count INTEGER NOT NULL DEFAULT 0,
          last_sku TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(account, server)
        )
      SQL
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
      # capsicum#468 リグレッションの自己修復。legacy_alter_table 未指定の
      # subscriptions 組み替えを経た環境では FK が subscriptions_old を指したまま
      # 壊れているので、正しい FK で作り直す（冪等。壊れていなければ何もしない）。
      repair_announcement_subscriptions_fk!
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_announcement_subscriptions_server
        ON announcement_subscriptions(server)
      SQL
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_announcement_subscriptions_push_token
        ON announcement_subscriptions(push_token)
      SQL
    end

    # capsicum#468 リグレッションの自己修復。announcement_subscriptions の FK が
    # 存在しない subscriptions_old を参照している場合、正しい FK
    # (subscriptions(push_token)) で作り直す。冪等で、壊れていなければ何もしない。
    # 当テーブルを rename する際も legacy_alter_table=ON で FK の二次書き換えを
    # 防ぐ（rebuild_subscriptions_table! と同じ理由）。
    def repair_announcement_subscriptions_fk!
      schema = @db.execute(<<~SQL).first
        SELECT sql FROM sqlite_master
        WHERE type = 'table' AND name = 'announcement_subscriptions'
      SQL
      return unless schema && schema['sql'].include?('subscriptions_old')

      @db.execute('PRAGMA foreign_keys=OFF')
      @db.execute('PRAGMA legacy_alter_table=ON')
      begin
        @db.transaction do
          @db.execute(
            'ALTER TABLE announcement_subscriptions RENAME TO announcement_subscriptions_broken',
          )
          @db.execute(<<~SQL)
            CREATE TABLE announcement_subscriptions (
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
            INSERT INTO announcement_subscriptions
              (id, push_token, server, account, created_at, updated_at)
            SELECT id, push_token, server, account, created_at, updated_at
            FROM announcement_subscriptions_broken
          SQL
          @db.execute('DROP TABLE announcement_subscriptions_broken')
        end
      ensure
        @db.execute('PRAGMA legacy_alter_table=OFF')
        @db.execute('PRAGMA foreign_keys=ON')
      end
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

    # device_id は nullable。device-id を送らない旧クライアントが従来どおり
    # (token, account, server) をキーに動き続けられるようにするため (#15)。
    # 実質的な UNIQUE(account, server, device_id) は migrate! の部分インデックス
    # 側で張る（SQLite はテーブル制約に WHERE を書けないため）。
    def create_subscriptions_table!
      @db.execute(<<~SQL)
        CREATE TABLE subscriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          token TEXT NOT NULL,
          push_token TEXT NOT NULL UNIQUE,
          device_type TEXT NOT NULL CHECK(device_type IN ('ios', 'android', 'macos', 'windows')),
          account TEXT NOT NULL,
          server TEXT NOT NULL,
          device_id TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(token, account, server)
        )
      SQL
    end

    def migrate_to_subscription_scoped!
      rebuild_subscriptions_table! do
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
      end
    end

    # device_type CHECK 拡張 (#468 macos / #474 windows) のための組み替え。最新
    # スキーマで作り直し、旧テーブルの全行をそのままコピーする。
    def rebuild_with_all_rows!
      rebuild_subscriptions_table! do
        old_columns = table_columns('subscriptions_old')
        list = COPYABLE_SUBSCRIPTION_COLUMNS.select {|c| old_columns.include?(c)}.join(', ')
        @db.execute("INSERT INTO subscriptions (#{list}) SELECT #{list} FROM subscriptions_old")
      end
    end

    def table_columns(table)
      return @db.execute("PRAGMA table_info(#{table})").map {|c| c['name']}
    end

    # subscriptions テーブルの CHECK / UNIQUE 等 ALTER 不能な変更のための
    # 組み替え共通処理。rename → 新スキーマ作成 → block でコピー → old drop。
    #
    # 子テーブル (announcement_subscriptions) が subscriptions(push_token) を FK
    # 参照しているため、素朴に rename すると SQLite が子テーブルの FK 参照名を
    # subscriptions_old へ自動書き換えし (legacy_alter_table OFF の既定動作)、
    # subscriptions_old を drop した後に FK がダングリングして以後の
    # announcement_subscriptions への INSERT が "no such table: subscriptions_old"
    # で 500 になる (capsicum#468 で実際に発生・リグレッション)。
    # legacy_alter_table=ON で rename を子テーブルに伝播させないことで防ぐ
    # (SQLite 公式の table-rebuild 手順)。foreign_keys は transaction 内では
    # 切り替えられないため transaction の外で OFF/ON する。
    def rebuild_subscriptions_table!
      @db.execute('PRAGMA foreign_keys=OFF')
      @db.execute('PRAGMA legacy_alter_table=ON')
      begin
        @db.transaction do
          @db.execute('ALTER TABLE subscriptions RENAME TO subscriptions_old')
          create_subscriptions_table!
          yield
          @db.execute('DROP TABLE subscriptions_old')
        end
      ensure
        @db.execute('PRAGMA legacy_alter_table=OFF')
        @db.execute('PRAGMA foreign_keys=ON')
      end
    end
  end
end
