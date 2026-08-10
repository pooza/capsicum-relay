require_relative 'test_helper'
require 'fileutils'
require 'logger'
require 'securerandom'
require 'sqlite3'
require 'tmpdir'
require 'lib/relay/database'

# device_id 導入前 (capsicum#932 以前) のクライアントが残した孤児行の掃除
# (capsicum#949 / capsicum-relay#15)。
#
# 旧版は push トークンが変わるたびに新しい行を作っており、その行は上流の購読が
# 生きている限り push され続けるため **1 通の通知が行数ぶん増える**。2026-08-10 に
# 実機で確認した例では windows 3 行 = 3 通で、行を消したら 1 通に戻った。
#
# 掃除は「生きている別端末を巻き込まない」ことが最重要なので、そこを厚く固定する。
class LegacyRowPurgeTest < Minitest::Test
  ACCOUNT = 'pooza@misskey.delmulin.com'.freeze
  SERVER = 'misskey.delmulin.com'.freeze

  def setup
    @dir = Dir.mktmpdir('relay-legacy-purge-test')
    @original_db_path = Relay::Database::DB_PATH
    swap_db_path(File.join(@dir, 'relay.sqlite3'))
    @db = Relay::Database.new(logger: Logger.new(File::NULL))
  end

  def teardown
    swap_db_path(@original_db_path)
    FileUtils.remove_entry(@dir)
  end

  # 本題。旧版が残した古い行は、新版が登録した時点で消える。
  def test_stale_legacy_rows_are_purged_when_the_new_client_registers
    legacy = insert_legacy_row('old-wns-uri-1', days_ago: 30)
    other_legacy = insert_legacy_row('old-wns-uri-2', days_ago: 20)

    @db.register(
      token: 'new-wns-uri', device_type: 'windows',
      account: ACCOUNT, server: SERVER, device_id: 'install-a'
    )

    assert_nil(@db.find(legacy['id']))
    assert_nil(@db.find(other_legacy['id']))
    assert_equal(1, rows_for('windows').length)
  end

  # 猶予内の行は残す。**同じ OS の別実機がまだ旧版で動いている**ケースを
  # 巻き込まないための線引きで、ここが緩むと生きた端末が不達になる。
  def test_recently_seen_legacy_rows_are_kept
    fresh = insert_legacy_row('another-live-pc', days_ago: 3)

    @db.register(
      token: 'new-wns-uri', device_type: 'windows',
      account: ACCOUNT, server: SERVER, device_id: 'install-a'
    )

    refute_nil(@db.find(fresh['id']))
  end

  # 端末種別が違う行は対象外。Windows の更新で Android の行を消してはいけない。
  def test_other_device_types_are_untouched
    android = insert_legacy_row('old-fcm-token', days_ago: 60, device_type: 'android')

    @db.register(
      token: 'new-wns-uri', device_type: 'windows',
      account: ACCOUNT, server: SERVER, device_id: 'install-a'
    )

    refute_nil(@db.find(android['id']))
  end

  # 別アカウント / 別サーバーの行も対象外（同一端末に複数垢を載せる運用）。
  def test_other_accounts_are_untouched
    other = insert_legacy_row('old-uri', days_ago: 60, account: 'someone@else.example')

    @db.register(
      token: 'new-wns-uri', device_type: 'windows',
      account: ACCOUNT, server: SERVER, device_id: 'install-a'
    )

    refute_nil(@db.find(other['id']))
  end

  # device_id 付きの行は、古くても消さない。別の実機（新版）かもしれないため。
  def test_rows_with_device_id_are_never_purged
    sibling = insert_legacy_row('other-install-uri', days_ago: 90, device_id: 'install-b')

    @db.register(
      token: 'new-wns-uri', device_type: 'windows',
      account: ACCOUNT, server: SERVER, device_id: 'install-a'
    )

    refute_nil(@db.find(sibling['id']))
  end

  # 旧クライアント（device_id なし）の登録では掃除しない。掃除の前提は
  # 「そのインストールが新版へ更新済み」なので、旧版の登録で走らせては困る。
  def test_legacy_client_registration_does_not_purge
    legacy = insert_legacy_row('old-uri', days_ago: 60)

    @db.register(token: 'another-old-uri', device_type: 'windows', account: ACCOUNT, server: SERVER)

    refute_nil(@db.find(legacy['id']))
  end

  # 自分自身を消さない。旧行を adopt して device_id を埋めた直後でも、
  # その行が purge の対象に入ってはいけない（入ると登録のたびに消える）。
  def test_the_row_just_registered_is_kept
    adopted = insert_legacy_row('kept-uri', days_ago: 60)

    result = @db.register(
      token: 'kept-uri', device_type: 'windows',
      account: ACCOUNT, server: SERVER, device_id: 'install-a'
    )

    assert_equal(adopted['id'], result['id'])
    refute_nil(@db.find(result['id']))
    assert_equal('install-a', result['device_id'])
  end

  # 孤児を消すと、その行にぶら下がるお知らせ購読も FK の CASCADE で消える。
  def test_purge_cascades_to_announcement_subscriptions
    legacy = insert_legacy_row('old-uri', days_ago: 60)
    @db.register_announcement_subscription(
      push_token: legacy['push_token'], server: SERVER, account: ACCOUNT,
    )

    @db.register(
      token: 'new-wns-uri', device_type: 'windows',
      account: ACCOUNT, server: SERVER, device_id: 'install-a'
    )

    assert_empty(@db.find_announcement_subscriptions_by_push_token(legacy['push_token']))
  end

  private

  def swap_db_path(path)
    Relay::Database.send(:remove_const, :DB_PATH)
    Relay::Database.const_set(:DB_PATH, path)
  end

  # 旧クライアントが作ったのと同じ形の行を、更新時刻を指定して直接入れる。
  # register 経由だと updated_at が now になり、猶予の検証ができない。
  def insert_legacy_row(token, days_ago:, device_type: 'windows', account: ACCOUNT,
    device_id: nil)
    params = [token, SecureRandom.hex(32), device_type, account, SERVER, device_id,
      days_ago, days_ago]
    raw do |db|
      db.execute(<<~SQL, params)
        INSERT INTO subscriptions
          (token, push_token, device_type, account, server, device_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now', '-' || ? || ' days'),
                datetime('now', '-' || ? || ' days'))
      SQL
    end
    return raw {|db| db.execute('SELECT * FROM subscriptions WHERE token = ?', [token])}.first
  end

  def rows_for(device_type)
    return raw do |db|
      db.execute(
        'SELECT * FROM subscriptions WHERE account = ? AND server = ? AND device_type = ?',
        [ACCOUNT, SERVER, device_type],
      )
    end
  end

  def raw
    db = SQLite3::Database.new(Relay::Database::DB_PATH)
    db.results_as_hash = true
    return yield(db)
  ensure
    db&.close
  end
end
