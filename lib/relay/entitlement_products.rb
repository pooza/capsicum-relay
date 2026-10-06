module Relay
  # リレー利用権として扱うストアの商品 (#89)。
  #
  # ⚠⚠ **ストアの応答を「この購入は利用権か」で絞る。**`bundleId` / `packageName` は
  # 「このアプリの購入か」しか言わないので、照合しないと**アプリの別のサブスクでも
  # 利用権が通る**。いまはサブスクが 1 本なので実害は無いが、2 本目を足した瞬間に
  # 顕在化する（そのときにここを思い出せる保証が無い）。
  #
  # ⚠ 投げ銭（消耗型）は `subscriptions` の API に出てこないので、ここには入れない。
  module EntitlementProducts
    DEFAULT = ['supporter.relay.monthly'].freeze

    # settings.yml のストアの節（`app_store` / `google_play`）から読む。
    # ⚠ `product_ids` が無い・空なら [DEFAULT]（**空のまま受けると全購入が
    # 「知らない」になり、7 日で失効へ落ちる**）。
    def self.from(section)
      ids = Array(section['product_ids']).map(&:to_s).reject(&:empty?)
      return ids.empty? ? DEFAULT : ids.freeze
    end
  end
end
