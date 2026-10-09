module Relay
  # ストアの API に届かない・ストア側の障害・鍵や権限が使えない (#61 / #62)。
  #
  # ⚠⚠ **呼び出し側は状態を変えずに抜ける（fail-open）。**有効な購入を「確かめられ
  # なかった」だけで失効扱いにしない。ストアごとのクライアントはこれを継いだ例外を投げ、
  # [Relay::StoreVerification] が 1 か所で拾う。
  class StoreUnavailable < StandardError; end

  # ストアの応答の形・署名・宛先（bundleId / packageName）が合わない。状態は変えない。
  class StoreResponseInvalid < StandardError; end

  # 購入は実在するが、リレー利用権の商品ではない (#93)。
  #
  # ⚠⚠ **「知らない購入」（`not_found`）と分ける。**同じに数えると、`product_ids` の
  # 設定を誤ったとき、**正当な購入が全部「知らない」に倒れ、連続が終端の日数に
  # 達すると `revoked` まで進む**。metrics と `entitlement.issued` からも、でたらめな
  # `purchase_id` と区別できなかった。⚠ **終端へは数えない**（設定を直せば戻れる
  # ようにする）。
  class StoreProductMismatch < StandardError; end
end
