require_relative 'test_helper'
require 'logger'
require 'tmpdir'
require 'lib/relay/app_store_client'
require 'lib/relay/store_verification'
require 'lib/relay/database'
require 'lib/relay/entitlement_reverifier'
require 'lib/relay/metrics'

# #61（Codex P1 / P2・PR #75）: 検証の順序と、確かめ直しのワーカー。
class AppStoreVerificationTest < Minitest::Test
  Settings = Struct.new(:app_store, :database, :logger, :metrics, :config, keyword_init: true)

  # 取引 ID ごとに、返す結果（と待ち時間）を決めておく App Store Server API の偽物。
  class FakeAppStore
    attr_reader :calls

    def initialize(&responder)
      @responder = responder
      @calls = Queue.new
    end

    def purchase_status(transaction_id)
      @calls << transaction_id
      return @responder.call(transaction_id, @calls.size)
    end
  end

  def setup
    @dir = Dir.mktmpdir('relay-verification-test')
    @db = Relay::Database.new(logger: Logger.new(File::NULL), path: File.join(@dir, 'relay.sqlite3'))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def settings(app_store)
    return Settings.new(
      app_store: app_store, database: @db, logger: Logger.new(File::NULL),
      metrics: Relay::Metrics.new, config: {}
    )
  end

  def result(status, original: '1000', signed_at: nil)
    return Relay::AppStoreClient::Result.new(
      original_transaction_id: original, product_id: 'relay.monthly', status: status,
      expires_at: nil, environment: 'Production', signed_at: signed_at
    )
  end

  def entitlement(purchase_id, device_id: 'device-1')
    return @db.issue_entitlement_token(
      store: 'apple', purchase_id: purchase_id, device_id: device_id,
    )['entitlement_id']
  end

  # --- 順序（Codex P2） ---------------------------------------------------------

  # ⚠⚠ 古い読み（active）が、後から来た新しい読み（expired）を上書きしない。
  # 1 本目は Apple の応答を待たせ、その間に 2 本目を走らせる。
  def test_stale_read_does_not_overwrite_a_newer_one
    id = entitlement('1000')
    fake = FakeAppStore.new do |_, nth|
      next result('expired') unless nth == 1

      sleep(0.2)
      next result('active')
    end
    first = Thread.new {Relay::StoreVerification.verify!(settings(fake), store: 'apple', entitlement_id: id, purchase_ref: '1000')}
    sleep(0.05)
    second = Thread.new {Relay::StoreVerification.verify!(settings(fake), store: 'apple', entitlement_id: id, purchase_ref: '1000')}
    [first, second].each(&:join)

    assert_equal('expired', @db.find_entitlement('apple', '1000')['status'])
  end

  # ⚠⚠ 同じ購入でも、付け替え前の行は別の行 ID ＝ 別の鍵になる（Codex P2・PR #75）。
  # 別々の端末が別の取引 ID で送ってきた 2 行で、**後から書かれる古い結果**が新しい
  # 結果を上書きしないことを、ストアの署名時刻で保証する。
  def test_older_result_on_an_alias_row_does_not_overwrite_a_newer_one
    newer = entitlement('tx-b', device_id: 'device-b')
    older = entitlement('tx-a', device_id: 'device-a')
    Relay::StoreVerification.verify!(
      settings(FakeAppStore.new {result('expired', signed_at: 2000)}),
      store: 'apple', entitlement_id: newer, purchase_ref: 'tx-b',
    )
    Relay::StoreVerification.verify!(
      settings(FakeAppStore.new {result('active', signed_at: 1000)}),
      store: 'apple', entitlement_id: older, purchase_ref: 'tx-a',
    )

    row = @db.find_entitlement('apple', '1000')

    assert_equal('expired', row['status'])
    assert_equal(1, @db.entitlement_count)
    assert_equal(2, @db.entitlement_tokens_for_purchase('apple', '1000').size)
  end

  # 新しい結果は、古い結果の上に書ける（順方向は止めない）。
  def test_newer_result_overwrites_an_older_one
    id = entitlement('1000')
    [[1000, 'active'], [2000, 'expired']].each do |signed_at, status|
      Relay::StoreVerification.verify!(
        settings(FakeAppStore.new {result(status, signed_at: signed_at)}),
        store: 'apple', entitlement_id: id, purchase_ref: '1000',
      )
    end

    assert_equal('expired', @db.find_entitlement('apple', '1000')['status'])
  end

  # --- 確かめ直し（Codex P1） ---------------------------------------------------

  # 登録時に Apple へ届かず transactionId のまま残った購入が、確かめ直しで
  # 元の取引 ID へ付け替わる（以後の通知で引ける）。
  def test_reverifier_canonicalizes_a_purchase_left_unverified
    entitlement('2000')
    fake = FakeAppStore.new {result('active')}
    count = Relay::EntitlementReverifier.new(settings(fake)).run_once

    assert_equal(1, count)
    assert_equal('active', @db.find_entitlement('apple', '1000')['status'])
    assert_nil(@db.find_entitlement('apple', '2000'))
  end

  # 検証済みの行は確かめ直さない（Apple API を無駄に叩かない）。
  def test_reverifier_skips_verified_purchases
    entitlement('2000')
    Relay::EntitlementReverifier.new(settings(FakeAppStore.new {result('active')})).run_once
    fake = FakeAppStore.new {result('active')}

    assert_equal(0, Relay::EntitlementReverifier.new(settings(fake)).run_once)
    assert_equal(0, fake.calls.size)
  end

  # ⚠ 作られてから 7 日を過ぎた行は対象外（誰でも作れる行で API を叩かせない）。
  def test_reverifier_ignores_old_unverified_purchases
    id = entitlement('2000')
    raw_update("UPDATE entitlements SET created_at = datetime('now', '-8 days') WHERE id = #{id}")
    fake = FakeAppStore.new {nil}

    assert_equal(0, Relay::EntitlementReverifier.new(settings(fake)).run_once)
  end

  # ⚠ 1 回に確かめるのは BATCH 件まで。見つからなかった行は順番の後ろへ回る。
  def test_reverifier_is_bounded_and_rotates
    ids = Array.new(Relay::EntitlementReverifier::BATCH + 5) {|i| entitlement("tx-#{i}", device_id: "d-#{i}")}
    raw_update("UPDATE entitlements SET updated_at = datetime('now', '-1 hour')")
    fake = FakeAppStore.new {nil}
    reverifier = Relay::EntitlementReverifier.new(settings(fake))

    assert_equal(Relay::EntitlementReverifier::BATCH, reverifier.run_once)
    seen = Array.new(fake.calls.size) {fake.calls.pop}
    reverifier.run_once
    second = Array.new(fake.calls.size) {fake.calls.pop}

    assert_equal(ids.size, (seen + second).uniq.size, '2 周目で残りの行に届いていない')
  end

  def test_reverifier_does_not_start_without_app_store
    assert_nil(Relay::EntitlementReverifier.start_from_settings(settings(nil)))
  end

  private

  def raw_update(sql)
    db = SQLite3::Database.new(File.join(@dir, 'relay.sqlite3'))
    db.execute(sql)
  ensure
    db&.close
  end
end
