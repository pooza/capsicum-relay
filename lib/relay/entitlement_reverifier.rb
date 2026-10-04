require_relative 'store_verification'

module Relay
  # `unverified` のまま残った購入を、一定間隔でストアの API に確かめ直す
  # （Codex P1・PR #75。Apple で入れ、#62 で Google も回す）。
  #
  # ⚠⚠ **なぜ要るか。**購入の登録（`POST /entitlements`）で Apple に届かないと、行は
  # **クライアントが送った transactionId のまま** `unverified` で残る（fail-open）。
  # Apple の通知は元の取引 ID と**そのときの** transactionId を持って来るので、更新の後の
  # 通知ではどちらの ID でもこの行に当たらない。クライアントが送り直すまで、正当な購入が
  # 利用権として通らないままになる。
  #
  # 確かめ直せば、Apple の応答で元の取引 ID へ付け替わり、以後の通知で引けるようになる。
  # ⚠ Google は purchaseToken がそのまま購入の識別子なので付け替えは起きないが、登録時に
  # Google に届かなかった購入が `unverified` のまま残るのは同じ。
  #
  # ⚠ **1 回に [BATCH] 件・作られてから [WINDOW_DAYS] 日以内だけ。**`unverified` の行は
  # 誰でも作れるので、Apple API を叩く量を縛る（[Relay::Database#unverified_entitlements]）。
  class EntitlementReverifier
    DEFAULT_INTERVAL = 600
    BATCH = 20
    WINDOW_DAYS = 7

    # 検証済みの行を引き直す間隔の目安 (#63)。⚠ **これは「最後に触ってから」の
    # 日数**で、期限切れ・期限不明の行は日数を待たずに毎周引く
    # （[Relay::Database#stale_entitlements]）。
    STALE_DAYS = 7

    # ストアが「その購入は知らない」と答え続ける行の扱い (#63)。
    #
    # ⚠⚠ **`not_found` は行を触らない**（ストアの応答で状態を上書きしない fail-open の
    # 一種）ので、**何もしなければ終端にも落ちず、掃除の除外にも入らない。**
    # ステージングでは行 3 つに対して not_found が 694 回出ていた（2026-10-05 実測）。
    #
    # - [NOT_FOUND_GRACE_CHECKS]: ここまでは従来どおり毎周引く。⚠ **買った直後の
    #   伝播待ちを待たせないため** —— その行は `unverified` でゲートが deny し、
    #   自動で治す経路はこの掃除だけ（クライアントは起動時に `POST /entitlements` を
    #   送り直さない）。既定の 600 秒間隔なら約 30 分ぶん
    # - [NOT_FOUND_BACKOFF_DAYS]: 猶予を使い切った行を引き直す間隔
    # - [NOT_FOUND_TERMINAL_DAYS]: ここまで続いたら `revoked` へ落とす
    #   （[Relay::Database#record_entitlement_not_found]）
    NOT_FOUND_GRACE_CHECKS = 3
    NOT_FOUND_BACKOFF_DAYS = 1
    NOT_FOUND_TERMINAL_DAYS = 7

    # どのストアのクライアントも無い・`reverify_interval` が 0 以下なら起動しない（nil）。
    # ⚠ 間隔は `app_store.reverify_interval` を見る（最初に入った設定の置き場。Google だけの
    # 構成でも既定の 600 秒で動く）。
    def self.start_from_settings(settings)
      return nil if stores(settings).empty?

      interval = Integer(settings.config.dig('app_store', 'reverify_interval') || DEFAULT_INTERVAL)
      return nil unless interval.positive?

      return new(settings, interval: interval).start!
    end

    # クライアントが設定されているストア。
    def self.stores(settings)
      return Relay::StoreVerification::CLIENTS.keys.select do |store|
        Relay::StoreVerification.client_for(settings, store)
      end
    end

    def initialize(settings, interval: DEFAULT_INTERVAL)
      @settings = settings
      @interval = interval
    end

    def start!
      @thread = Thread.new do
        loop do
          run_once
        rescue StandardError => e
          # ⚠ 1 回の失敗で止めない（次の周回でまた確かめる）。
          @settings.logger.error("Entitlement reverify failed: #{e.class}: #{e.message}")
        ensure
          sleep @interval
        end
      end
      return self
    end

    def stop!
      @thread&.kill
    end

    # 1 周ぶん。確かめた件数を返す。⚠ 件数の縛り（[BATCH]）はストアごと。
    def run_once
      return self.class.stores(@settings).sum {|store| run_store(store)}
    end

    private

    # ⚠ **2 種類を回す。**`unverified`（誰でも作れる行・期間と件数で縛る）と、
    # **検証済みだが状態を信用できない行**（通知の取りこぼし・#63）。
    # ⚠⚠ **件数はそれぞれ [BATCH] 件。**片方が枠を食い切って、もう片方が永久に
    # 回らない形にしない。
    def run_store(store)
      unverified = @settings.database.unverified_entitlements(
        store, days: WINDOW_DAYS, limit: BATCH, **not_found_pacing
      )
      stale = @settings.database.stale_entitlements(
        store, limit: BATCH, stale_days: STALE_DAYS, **not_found_pacing
      )
      verify_rows(store, unverified, sweep: 'unverified')
      verify_rows(store, stale, sweep: 'stale')
      return unverified.size + stale.size
    end

    # ⚠ `sweep` のラベルを分ける —— **どちらの掃除が当たっているか**が分からないと、
    # 「通知の取りこぼしが実際に起きているのか」を測れない。
    def verify_rows(store, rows, sweep:)
      rows.each do |row|
        outcome, = Relay::StoreVerification.verify!(
          @settings, store: store, entitlement_id: row['id'], purchase_ref: row['purchase_id']
        )
        record_outcome(row['id'], outcome)
        @settings.metrics.increment('relay_entitlement_verify_total',
          {store: store, outcome: outcome, sweep: sweep})
      end
    end

    # ⚠⚠ **「知らない」と「届かない」を同じ扱いにしない** (#63)。
    #
    # | outcome | ここでやること |
    # | --- | --- |
    # | `not_found` | 連続を数え、[NOT_FOUND_TERMINAL_DAYS] 日続いたら終端へ落とす |
    # | `unavailable` / `invalid` | 順番の後ろへ回すだけ（⚠ **ストア障害で失効させない**） |
    # | ストアの状態 | 何もしない（[Relay::Database#update_entitlement_verification!] が数えを戻す） |
    def record_outcome(entitlement_id, outcome)
      if outcome == 'not_found'
        return @settings.database.record_entitlement_not_found(
          entitlement_id, terminal_days: NOT_FOUND_TERMINAL_DAYS
        )
      end

      # 反映されなかった行（届かない・署名が合わない）を順番の後ろへ回す。
      return @settings.database.touch_entitlement(entitlement_id) if
        ['unavailable', 'invalid'].include?(outcome)

      return nil
    end

    def not_found_pacing
      return {grace: NOT_FOUND_GRACE_CHECKS, backoff_days: NOT_FOUND_BACKOFF_DAYS}
    end
  end
end
