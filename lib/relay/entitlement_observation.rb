module Relay
  # `/register` が見た利用権の状況 (capsicum#597 / #59)。**観測だけ。**
  #
  # ⚠⚠ **ここでは何も拒まない。**この Issue で見たいのは「**非プリセット かつ
  # 利用権なしの登録がどれだけあるか**」で、フェーズ 3 でゲートを実際に閉じた
  # ときに誰が影響を受けるかを先に知るためのもの。
  #
  # ⚠ 引数は**既に引いた行**を受け取る（DB を触らない）。判定の規則だけを 1 か所に
  # 置いて、route から切り離して検査できるようにするため。
  module EntitlementObservation
    # 利用権が 1 つも無い。
    NONE = 'none'.freeze

    # クライアントが token を送ってこなかった。
    TOKEN_NONE = 'none'.freeze

    # 送ってきた token を relay が知らない。⚠ **これは異常の合図**（別の relay
    # 向けの token・手で作った値・DB を戻した後）。拒まないが数える。
    TOKEN_UNKNOWN = 'unknown'.freeze

    # token は実在するが、**登録に来た端末とは別の端末のもの**。
    # ⚠⚠ **ゲート（#60）は `subscriptions.device_id` から引く**ので、この状態の
    # 端末はフェーズ 3 で**止まる**。token を送れているのに止まる、という
    # いちばん分かりにくい形なので、フェーズ 1 のうちに数えておく。
    TOKEN_MISMATCH = 'mismatch'.freeze

    # token が実在し、登録に来た端末のものだった。
    TOKEN_OK = 'ok'.freeze

    # 「有効に近い」順。⚠⚠ **ゲート（#60）もこの順を使う。**1 端末が複数の購入に
    # ぶら下がりうる（買い直し・別ストア）ので、代表を 1 つ選ぶ規則が要る。
    # ⚠ `unverified` は `expired` より上に来るが、**許可を意味しない** —— 誰でも
    # 作れる行なので（#58）、ゲートの許可側に入れてはいけない。
    STATUS_PRIORITY = ['active', 'grace', 'unverified', 'expired', 'revoked'].freeze

    # [device_tokens] は `Database#entitlement_tokens_for_device` の戻り。
    # [claimed] は `Database#find_entitlement_token` の戻り（送られた token・無ければ nil）。
    def self.classify(preset:, device_tokens:, claimed:, device_id:, token_sent:)
      return {
        preset: preset ? 'yes' : 'no',
        entitlement: best_status(device_tokens),
        token: token_state(claimed: claimed, device_id: device_id, token_sent: token_sent),
      }
    end

    def self.best_status(device_tokens)
      statuses = Array(device_tokens).map {|row| row['status'].to_s}.reject(&:empty?)
      return NONE if statuses.empty?

      # ⚠ 知らない status は最下位（上流が増やした値を「有効に近い」と読まない）。
      return statuses.min_by {|status| STATUS_PRIORITY.index(status) || STATUS_PRIORITY.size}
    end

    def self.token_state(claimed:, device_id:, token_sent:)
      return TOKEN_NONE unless token_sent
      return TOKEN_UNKNOWN unless claimed
      # ⚠ 両方 nil / 空のときに「一致」と読まない。token 側の device_id は
      # NOT NULL なので、空になるのは register 側（旧クライアント）だけ。
      return TOKEN_MISMATCH if device_id.to_s.empty?

      return claimed['device_id'] == device_id ? TOKEN_OK : TOKEN_MISMATCH
    end
  end
end
