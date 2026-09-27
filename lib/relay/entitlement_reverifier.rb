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

    def run_store(store)
      rows = @settings.database.unverified_entitlements(store, days: WINDOW_DAYS, limit: BATCH)
      rows.each do |row|
        outcome, = Relay::StoreVerification.verify!(
          @settings, store: store, entitlement_id: row['id'], purchase_ref: row['purchase_id']
        )
        # 反映されなかった行（見つからない・届かない）を順番の後ろへ回す。
        @settings.database.touch_entitlement(row['id'])
        @settings.metrics.increment('relay_entitlement_verify_total',
          {store: store, outcome: outcome})
      end
      return rows.size
    end
  end
end
