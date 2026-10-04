require_relative 'test_helper'
require 'logger'
require 'tmpdir'
require 'delegate'
require 'lib/relay/app_store_client'
require 'lib/relay/google_play_client'
require 'lib/relay/store_verification'
require 'lib/relay/database'
require 'lib/relay/entitlement_reverifier'
require 'lib/relay/metrics'

# #61（Codex P1 / P2・PR #75）: 検証の順序と、確かめ直しのワーカー。
class AppStoreVerificationTest < Minitest::Test
  Settings = Struct.new(:app_store, :google_play, :database, :logger, :metrics, :config, keyword_init: true)

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

  # `record_entitlement_not_found` が**鍵を握ったまま**呼ばれているかを捕まえる
  # （PR #86 の Codex P2）。
  class LockWatchingDatabase < SimpleDelegator
    attr_reader :locked_when_recorded

    def record_entitlement_not_found(entitlement_id, **)
      @locked_when_recorded = Relay::StoreVerification.lock_for(entitlement_id).owned?
      return __getobj__.record_entitlement_not_found(entitlement_id, **)
    end
  end

  def setup
    @dir = Dir.mktmpdir('relay-verification-test')
    @db = Relay::Database.new(logger: Logger.new(File::NULL), path: File.join(@dir, 'relay.sqlite3'))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def settings(app_store, google_play: nil)
    return Settings.new(
      app_store: app_store, google_play: google_play, database: @db, logger: Logger.new(File::NULL),
      metrics: Relay::Metrics.new, config: {}
    )
  end

  def result(status, original: '1000', signed_at: nil, expires_at: nil)
    return Relay::AppStoreClient::Result.new(
      original_transaction_id: original, product_id: 'relay.monthly', status: status,
      expires_at: expires_at, environment: 'Production', signed_at: signed_at
    )
  end

  # 期限が先にある `active`（確かめ直しの対象にならない形）。
  FUTURE = '2099-01-01 00:00:00'.freeze

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

  # 期限が先にある検証済みの行は確かめ直さない（Apple API を無駄に叩かない）。
  def test_reverifier_skips_verified_purchases_within_their_period
    entitlement('2000')
    first = FakeAppStore.new {result('active', expires_at: FUTURE)}
    Relay::EntitlementReverifier.new(settings(first)).run_once
    fake = FakeAppStore.new {result('active', expires_at: FUTURE)}

    assert_equal(0, Relay::EntitlementReverifier.new(settings(fake)).run_once)
    assert_equal(0, fake.calls.size)
  end

  # ⚠⚠ **期限の無い検証済みの行は引き直す (#63)。**ゲートは期限が読めない `active` を
  # fail-open で通すので、放置すると**無期限に通る行**が残る。
  def test_reverifier_rechecks_verified_purchases_without_an_expiry
    entitlement('2000')
    Relay::EntitlementReverifier.new(settings(FakeAppStore.new {result('active')})).run_once
    fake = FakeAppStore.new {result('active', expires_at: FUTURE)}

    assert_equal(1, Relay::EntitlementReverifier.new(settings(fake)).run_once)
    assert_equal(1, fake.calls.size)
    assert_equal(FUTURE, @db.find_entitlement('apple', '1000')['expires_at'])
  end

  # ⚠⚠ **期限を過ぎた `active` は引き直す (#63)。**更新の通知を取りこぼすと行は
  # `active` のまま残るので、**払われている購読を止めてしまう**（逆に失効を
  # 取りこぼせば通し続ける）。どちらも通知任せでは直らない。
  def test_reverifier_rechecks_active_rows_past_their_expiry
    entitlement('2000')
    past = FakeAppStore.new {result('active', expires_at: '2020-01-01 00:00:00')}
    Relay::EntitlementReverifier.new(settings(past)).run_once
    fake = FakeAppStore.new {result('active', expires_at: FUTURE)}

    assert_equal(1, Relay::EntitlementReverifier.new(settings(fake)).run_once)
    assert_equal(FUTURE, @db.find_entitlement('apple', '1000')['expires_at'])
  end

  # ⚠ 終端の状態は引き直さない（終わった購入に永久に API を叩かない）。買い直しは
  # クライアント自身の `POST /entitlements` がその場で確かめる。
  def test_reverifier_leaves_terminal_rows_alone
    entitlement('2000')
    Relay::EntitlementReverifier.new(settings(FakeAppStore.new {result('expired')})).run_once
    fake = FakeAppStore.new {result('active', expires_at: FUTURE)}

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

  # #62: Google の `unverified` も確かめ直す（purchaseToken がそのまま識別子）。
  def test_reverifier_also_verifies_google_purchases
    @db.issue_entitlement_token(store: 'google', purchase_id: 'token-1', device_id: 'g')
    google = FakeAppStore.new do
      Relay::GooglePlayClient::Result.new(
        purchase_id: 'token-1', product_id: 'relay.monthly', status: 'active',
        expires_at: nil, environment: 'Production', signed_at: 1
      )
    end
    count = Relay::EntitlementReverifier.new(settings(nil, google_play: google)).run_once

    assert_equal(1, count)
    assert_equal('active', @db.find_entitlement('google', 'token-1')['status'])
  end

  def test_reverifier_does_not_start_without_app_store
    assert_nil(Relay::EntitlementReverifier.start_from_settings(settings(nil)))
  end

  # --- ストアが「知らない」と言い続ける行 (#63) ----------------------------------

  # ⚠⚠ **買った直後は待たせない。**ストアへの伝播が遅れると行は `unverified` のまま
  # 残り、**ゲートは deny する**。自動で治す経路はこの掃除だけ（クライアントは起動時に
  # `POST /entitlements` を送り直さず、持っている token で読むだけ）なので、
  # 最初の [NOT_FOUND_GRACE_CHECKS] 回は従来どおり毎周引く。
  def test_reverifier_keeps_rechecking_right_after_a_not_found
    entitlement('2000')
    fake = FakeAppStore.new {nil}
    reverifier = Relay::EntitlementReverifier.new(settings(fake))
    Relay::Database::NOT_FOUND_GRACE_CHECKS.times {reverifier.run_once}

    assert_equal(Relay::Database::NOT_FOUND_GRACE_CHECKS, fake.calls.size)
  end

  # ⚠⚠ **毎周を永久に続けない。**猶予を使い切ったらバックオフする。ステージングでは
  # 行 3 つに対して not_found が 694 回出ており（2026-10-05 実測）、**ストアが知らない
  # 購入へ 10 分ごとに永久に API を叩いていた**。
  def test_reverifier_backs_off_after_repeated_not_found
    entitlement('2000')
    fake = FakeAppStore.new {nil}
    reverifier = Relay::EntitlementReverifier.new(settings(fake))
    (Relay::Database::NOT_FOUND_GRACE_CHECKS + 2).times {reverifier.run_once}

    assert_equal(Relay::Database::NOT_FOUND_GRACE_CHECKS, fake.calls.size,
      '猶予を使い切った行をまだ毎周引いている')
  end

  # バックオフが明けたら 1 回だけ引く（諦めてはいない）。
  def test_reverifier_rechecks_once_a_day_while_the_store_denies_it
    id = entitlement('2000')
    fake = FakeAppStore.new {nil}
    reverifier = Relay::EntitlementReverifier.new(settings(fake))
    (Relay::Database::NOT_FOUND_GRACE_CHECKS + 1).times {reverifier.run_once}
    before = fake.calls.size
    release_backoff(id)
    reverifier.run_once

    assert_equal(before + 1, fake.calls.size)
  end

  # ⚠⚠ **[NOT_FOUND_TERMINAL_DAYS] 日続いたら終端へ落とす。**ゲートは期限の読めない
  # `active` を fail-open で通すので、放置すると「**ストアが知らない購入が無期限に
  # 通る**」行が残る。終端にすれば掃除の対象からも外れる。
  def test_reverifier_revokes_a_purchase_the_store_has_forgotten
    id = entitlement('2000')
    Relay::EntitlementReverifier.new(settings(FakeAppStore.new {result('active')})).run_once
    fake = FakeAppStore.new {nil}
    reverifier = Relay::EntitlementReverifier.new(settings(fake))
    reverifier.run_once
    forget_since(id, days: Relay::Database::NOT_FOUND_TERMINAL_DAYS + 1)
    reverifier.run_once
    calls = fake.calls.size

    assert_equal('revoked', @db.find_entitlement('apple', '1000')['status'])
    raw_update("UPDATE entitlements SET updated_at = datetime('now', '-2 days') WHERE id = #{id}")

    assert_equal(0, reverifier.run_once, '終端にした行をまだ引いている')
    assert_equal(calls, fake.calls.size)
  end

  # ⚠ ストアが答えたら数え直す（バックオフも終端までの日数も解ける）。
  def test_reverifier_clears_the_not_found_streak_when_the_store_answers
    entitlement('2000')
    nothing = FakeAppStore.new {nil}
    reverifier = Relay::EntitlementReverifier.new(settings(nothing))
    (Relay::Database::NOT_FOUND_GRACE_CHECKS - 1).times {reverifier.run_once}
    Relay::EntitlementReverifier.new(settings(FakeAppStore.new {result('active')})).run_once
    row = @db.find_entitlement('apple', '1000')

    assert_equal(0, row['not_found_streak'])
    assert_nil(row['not_found_since'])
  end

  # ⚠⚠ **`unverified` の行も終端へ落ちる**（PR #86 の Codex P2）。`not_found_since` が
  # 立つのは最初の掃除（作成 + 数分）なので、`created_at` 基準の窓（WINDOW_DAYS）は
  # 終端（NOT_FOUND_TERMINAL_DAYS・同じ 7 日）より**必ず先に閉じる** ＝ 連続が始まった
  # 行を窓だけで切ると、**約束した `revoked` に永久に到達しない。**
  def test_reverifier_revokes_an_unverified_row_that_aged_out_of_the_window
    id = entitlement('2000')
    fake = FakeAppStore.new {nil}
    reverifier = Relay::EntitlementReverifier.new(settings(fake))
    reverifier.run_once
    raw_update(
      "UPDATE entitlements SET created_at = datetime('now', '-8 days') WHERE id = #{id}",
    )
    forget_since(id, days: Relay::Database::NOT_FOUND_TERMINAL_DAYS + 1)
    reverifier.run_once

    assert_equal('revoked', @db.find_entitlement('apple', '2000')['status'])
    raw_update("UPDATE entitlements SET updated_at = datetime('now', '-2 days') WHERE id = #{id}")

    assert_equal(0, reverifier.run_once, '終端にした行をまだ引いている')
  end

  # 🔴 **前景の retry で終端を先送りできない**（PR #86 の Codex P2）。`POST /entitlements` の
  # upsert は `updated_at` を若返らせるので、**バックオフをあれで測ると purchase_id を
  # 知っている者が叩き続けるだけで終端に永久に到達しない**（`active` で期限が読めない行は
  # ゲートを fail-open で通るので、無期限に通る）。⚠ 共有シークレットは取り出せる前提。
  def test_foreground_retries_do_not_postpone_terminalization
    id = entitlement('2000')
    Relay::EntitlementReverifier.new(settings(FakeAppStore.new {result('active')})).run_once
    fake = FakeAppStore.new {nil}
    reverifier = Relay::EntitlementReverifier.new(settings(fake))
    Relay::Database::NOT_FOUND_GRACE_CHECKS.times {reverifier.run_once}
    # バックオフに入った行の `updated_at` だけを若返らせる（前景の upsert の模倣）。
    raw_update(
      "UPDATE entitlements SET not_found_checked_at = datetime('now', '-2 days')," \
        " updated_at = datetime('now') WHERE id = #{id}",
    )
    before = fake.calls.size
    reverifier.run_once

    assert_equal(before + 1, fake.calls.size, 'updated_at を若返らせるだけで掃除から外れている')
  end

  # ⚠⚠ **前景の `not_found` も数える**（PR #86 の Codex P2）。掃除だけで数えると、
  # 前景で叩き続けるかぎり連続が進まない。
  def test_foreground_not_found_counts_toward_the_streak
    id = entitlement('2000')
    Relay::StoreVerification.verify!(
      settings(FakeAppStore.new {nil}), store: 'apple', entitlement_id: id, purchase_ref: '2000'
    )

    assert_equal(1, @db.find_entitlement('apple', '2000')['not_found_streak'])
  end

  # ⚠⚠ **数えるのは購入ごとの鍵の中**（PR #86 の Codex P2）。鍵を解いたあとに数えると、
  # 同じ購入の**成功した検証と競合して、通ったばかりの行に連続を書き戻す**（連続が
  # 7 日に達していれば `revoked` まで行く ＝ **正当な購読者が次の明示的な検証まで
  # 拒否されたままになる**）。
  #
  # ⚠ **スレッドを 2 本走らせる形では確かめられない。**鍵を解いた直後に数える実装でも、
  # 成功側より先に書き終わってしまうので**素通りする**（2026-10-05 に実際に穴を開けて
  # 確認した）。**鍵を握っているかを直接見る。**
  def test_not_found_is_recorded_while_holding_the_purchase_lock
    id = entitlement('2000')
    watcher = LockWatchingDatabase.new(@db)
    with_watcher = settings(FakeAppStore.new {nil})
    with_watcher.database = watcher
    Relay::StoreVerification.verify!(
      with_watcher, store: 'apple', entitlement_id: id, purchase_ref: '2000'
    )

    assert(watcher.locked_when_recorded, '鍵を解いたあとに数えている（成功した検証と競合しうる）')
  end

  # ⚠⚠ **「届かない」は「知らない」ではない。**`unavailable` は fail-open なので、
  # バックオフも終端の数えも進めない（ストア障害で有効な購読を失効させない）。
  def test_reverifier_does_not_count_unavailable_as_not_found
    entitlement('2000')
    fake = FakeAppStore.new {raise(Relay::StoreUnavailable, 'boom')}
    reverifier = Relay::EntitlementReverifier.new(settings(fake))
    runs = Relay::Database::NOT_FOUND_GRACE_CHECKS + 2
    runs.times {reverifier.run_once}

    assert_equal(runs, fake.calls.size, 'ストア障害でバックオフに入っている')
    assert_equal(0, @db.find_entitlement('apple', '2000')['not_found_streak'])
  end

  private

  # その行を「[days] 日前から not_found が続いている」状態にし、バックオフも明けさせる。
  def forget_since(id, days:)
    raw_update(
      "UPDATE entitlements SET not_found_since = datetime('now', '-#{Integer(days)} days')," \
        " not_found_checked_at = datetime('now', '-2 days') WHERE id = #{Integer(id)}",
    )
  end

  # ⚠ バックオフの時計は `not_found_checked_at`（`updated_at` ではない・PR #86 の Codex P2）。
  def release_backoff(id)
    raw_update(
      "UPDATE entitlements SET not_found_checked_at = datetime('now', '-2 days')" \
        " WHERE id = #{Integer(id)}",
    )
  end

  def raw_update(sql)
    db = SQLite3::Database.new(File.join(@dir, 'relay.sqlite3'))
    db.execute(sql)
  ensure
    db&.close
  end
end
