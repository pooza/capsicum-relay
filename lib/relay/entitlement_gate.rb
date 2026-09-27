require_relative 'database'
require_relative 'preset_servers'

module Relay
  # 有償リレーの認可ゲート (capsicum#597 / #60)。**フェーズ 2（認可）。**
  #
  # ⚠⚠ **既定では何も閉じない。**[enforce?] が false のときは常に許可を返す。
  # 判定を実際に閉じるのはフェーズ 3 の決定で、⚠ **閉じる前に
  # `relay_register_entitlement_total` を読み直すこと**（設計書 2-4 の
  # 「ゲートを実際に閉じる前に測り直す」）。
  #
  # ⚠ **判定は 1 か所。**`/register` と `/push` の両方がここを通る。2 か所に書くと
  # **片方だけ閉じる**（登録は拒むのに既存の購読は叩き続ける、など）形になる。
  module EntitlementGate
    # 閉じるかどうかの切り替え。⚠ **env で持つ**（`PUSH_DEDUP_WINDOW_MS` と同じ形）。
    #
    # ⚠⚠ **既定は false。**コード上の定数にしなかったのは、**ステージングで
    # 閉じた側の経路（`410 Gone`）を踏めるようにするため**。本番で立てるのは
    # フェーズ 3 の決定。
    ENFORCE_ENV = 'RELAY_ENTITLEMENT_ENFORCE'.freeze

    # 許可する購入の状態。
    #
    # ⚠⚠ **`unverified` を入れない。**`POST /entitlements` の認証は共有シークレット
    # 1 本で、**そのシークレットはバイナリから取り出せる**（capsicum#1121）。
    # つまり誰でも `unverified` の行を作れるので、**入れるとゲートが無意味になる**。
    # 有効になるのはフェーズ 3 のレシート検証を通ってから（#61 / #62）。
    ENTITLED_STATUSES = ['active', 'grace'].freeze

    # 許可した / 拒んだ理由。metrics のラベルに出す。
    REASON_ENFORCE_OFF = 'enforce_off'.freeze
    REASON_PRESET = 'preset'.freeze
    REASON_ENTITLED = 'entitled'.freeze
    REASON_NO_ENTITLEMENT = 'no_entitlement'.freeze

    # プリセットを名乗ったが、**その鍵が引けなかった** (#69)。⚠⚠ **fail-open で
    # 通す。**引けないのは**こちらの障害**（相手が落ちている・DNS・こちらの
    # 外向き通信）で、⚠ **本物のプリセットの通知を止めるほうが取り返しがつかない。**
    REASON_PRESET_UNVERIFIABLE = 'preset_unverifiable'.freeze
    # プリセットを名乗ったが、**署名が無い / 読めない** (#69)。⚠ 本物の
    # Mastodon / Misskey は必ず VAPID を付けるので、**プリセット扱いをやめる。**
    REASON_PRESET_UNSIGNED = 'preset_unsigned'.freeze
    # プリセットを名乗ったが、**そのホストの鍵ではない** (#69)。⚠⚠ **詐称。**
    REASON_PRESET_MISMATCH = 'preset_mismatch'.freeze

    # [decide] の `preset_verification` に渡せる値。
    #
    # ⚠⚠ **`/register` は必ず [PRESET_NOT_CHECKED]。**あの経路を叩くのは
    # クライアント自身で、**fedi サーバーの署名が存在しない**。⚠ **止めるのは
    # `/push`**（設計書 決定済み事項 2-C）なので、登録を通しても穴は残らない ——
    # 手に入れた `push_token` を自分のサーバーへ向けた瞬間に `/push` で捕まる。
    PRESET_NOT_CHECKED = :not_checked
    PRESET_VERIFIED = :verified
    PRESET_UNAVAILABLE = :unavailable
    PRESET_UNSIGNED = :unsigned
    PRESET_MISMATCH = :mismatch

    # ⚠⚠ **判定に失敗したので通した。**この理由が出ているあいだゲートは効いて
    # いないので、**数が 0 でないことに気付けるようにする**のがラベルの役目。
    REASON_ERROR = 'error'.freeze

    def self.enforce?(env: ENV)
      return env[ENFORCE_ENV].to_s.strip == 'true'
    end

    # [subscription] は `subscriptions` の 1 行（`server` / `device_id` を読む）。
    #
    # 戻り値は `[許可か, 理由]`。⚠ **理由は拒否のときだけでなく許可のときも返す** ——
    # 「なぜ通ったのか」が分からないと、ゲートが効いていない状態に気付けない。
    #
    # ⚠⚠ **fail-open。**判定不能のときは**通す**。課金判定の失敗で無償ユーザーの
    # 通知が止まるのは取り返しがつかない（#60 の「絶対に守る 2 点」の 2）。
    # ⚠ `Exception` ではなく `StandardError` を拾う（`SignalException` や
    # Sinatra の制御用の投げものを飲まない）。
    def self.decide(subscription:, database:, preset_verification: PRESET_NOT_CHECKED,
      extra_preset_hosts: nil, env: ENV)
      return [true, REASON_ENFORCE_OFF] unless enforce?(env: env)
      # ⚠ **プリセットは判定に入る前に抜ける**（#60 の「絶対に守る 2 点」の 1）。
      # 「プリセットに 1 アカウント持てば全部無償」の穴は残すと決定済み
      # （2026-09-12・設計書 決定済み事項 3）。
      #
      # ⚠⚠ **`subscription['server']` はクライアントの申告で、それ自体は証拠に
      # ならない (#69)。**共有シークレットは authorization boundary にできない
      # （capsicum#1121）ので、⚠ **誰でも `server: "mstdn.b-shock.org"` と名乗れる。**
      # → **`/push` の VAPID 署名で裏を取る**（[preset_decision] / #69）。
      #
      # ⚠ **穴を塞いだのではない。**「プリセットに 1 アカウント持てば全部無償」は
      # **完全に意図通り**で残す（設計書 1-2 / 未決事項 3・2026-09-28 再評価）。
      # 塞ぐのは「**アカウントを作らずにプリセットを名乗れる**」ほうだけ ——
      # 迂回の対価が「身内が増える」であることが、この読み替えの前提だから。
      if Relay::PresetServers.preset?(subscription['server'], extra: extra_preset_hosts)
        allowed, reason = preset_decision(preset_verification)
        return [allowed, reason] if allowed

        # ⚠ **名乗りの裏が取れなかった場合は、プリセットでないものとして続ける。**
        # ここで即 deny にしない —— 購入している利用者がたまたまプリセットの
        # ホスト名で登録していることがありうる。
        return [true, REASON_ENTITLED] if entitled?(database, subscription['device_id'])

        # ⚠ 理由は **`no_entitlement` ではなくプリセット側の失敗**を返す。
        # 「利用権が無い」と「プリセットを詐称した」は対処がまったく違う。
        return [false, reason]
      end
      return [true, REASON_ENTITLED] if entitled?(database, subscription['device_id'])

      return [false, REASON_NO_ENTITLEMENT]
    rescue StandardError
      return [true, REASON_ERROR]
    end

    # プリセットを名乗った push を通すか。戻り値は `[許可か, 理由]`。
    #
    # ⚠⚠ **`unavailable` だけが fail-open。**「こちらが確かめられなかった」と
    # 「相手が署名していない / 鍵が違う」を**同じ倒し方にしない**のが要点
    # （#69 の完了条件「検証できないときの倒し方を決める」）。
    # ⚠ 署名が無いのを fail-open にすると、**ヘッダを付けないだけで迂回できる**
    # ＝ #69 を直したことにならない。
    def self.preset_decision(verification)
      case verification
      when PRESET_NOT_CHECKED, PRESET_VERIFIED then return [true, REASON_PRESET]
      when PRESET_UNAVAILABLE then return [true, REASON_PRESET_UNVERIFIABLE]
      when PRESET_MISMATCH then return [false, REASON_PRESET_MISMATCH]
      else return [false, REASON_PRESET_UNSIGNED]
      end
    end

    # ⚠ **`device_id` が NULL の行（旧クライアント）は利用権を引けない**ので false。
    # 非プリセットの旧クライアントは、ゲートを閉じたときに止まる。
    # ⚠⚠ 実測では該当 0 人（設計書 1-2）だが、**閉じる前に測り直すこと。**
    def self.entitled?(database, device_id)
      return false if device_id.to_s.empty?

      return database.entitlement_tokens_for_device(device_id).any? do |row|
        ENTITLED_STATUSES.include?(row['status'])
      end
    end
  end
end
