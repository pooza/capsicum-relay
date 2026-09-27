module Relay
  # ストアの API に届かない・ストア側の障害・鍵や権限が使えない (#61 / #62)。
  #
  # ⚠⚠ **呼び出し側は状態を変えずに抜ける（fail-open）。**有効な購入を「確かめられ
  # なかった」だけで失効扱いにしない。ストアごとのクライアントはこれを継いだ例外を投げ、
  # [Relay::StoreVerification] が 1 か所で拾う。
  class StoreUnavailable < StandardError; end

  # ストアの応答の形・署名・宛先（bundleId / packageName）が合わない。状態は変えない。
  class StoreResponseInvalid < StandardError; end
end
