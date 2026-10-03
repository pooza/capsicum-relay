require 'time'

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

    # 許可する購入の状態。⚠ **期限（`expires_at`）が切れていないことと AND**
    # （[within_period?]）。
    #
    # ⚠⚠ **`unverified` を入れない。**`POST /entitlements` の認証は共有シークレット
    # 1 本で、**そのシークレットはバイナリから取り出せる**（capsicum#1121）。
    # つまり誰でも `unverified` の行を作れるので、**入れるとゲートが無意味になる**。
    # 有効になるのはフェーズ 3 のレシート検証を通ってから（#61 / #62）。
    #
    # ⚠⚠ **`grace` は 2026-10-03 に外した**（#63 の判断・pooza）。支払いが通って
    # いない間は止める。⚠ **「判定できない」ときの fail-open とは別の話** ——
    # fail-open はストアへ問い合わせられないときに通す規則で、**未払いと分かって
    # いるものを通す理由にはならない**。
    ENTITLED_STATUSES = ['active'].freeze

    # 返金されても、**すでに決済した期間の終わりまでは通す**（2026-10-03 pooza 判断・
    # #63）。期限が来れば落ちる（[row_decision]）。
    #
    # ⚠⚠ **払った分の権利は否定しない、という判断**（2026-10-03 pooza）。⚠ ただし
    # **期間を延ばすことはしない** —— プリセット外の利用者に、こちらの持ち出しで
    # 配慮はしない方針。決済の管理は本人の責任で、個別の問い合わせには応じる。
    # ⚠ したがって未払い（[UNPAID_STATUSES]）は止める側に置く。
    #
    # ⚠ **Google の案内とは違う。**`SUBSCRIPTION_REVOKED` は「即座にアクセスを
    # 取り消す」ことを想定している。
    REFUNDED_STATUSES = ['revoked'].freeze

    # ストアの応答で「購読の期間が存在する」状態。⚠ **`expires_at` が必ず付く**ので、
    # 付いていない応答は形が崩れているとみなす（PR #76 の Codex P2・
    # `google_play_client` の `result_from`）。
    #
    # ⚠⚠ **[ENTITLED_STATUSES] を流用しない。**あちらは「通すか」、こちらは
    # 「応答が妥当か」で、**別の問い**。2026-10-03 に `grace` を許可側から外したとき、
    # 流用していた `google_play_client` の検査が**黙って緩んだ**（期限の無い `grace` を
    # 受け入れるようになった）。⚠ 流用は「同じ中身だから」で始まり、中身が変わった
    # ときに気付けない。
    STATUSES_WITH_PERIOD = ['active', 'grace'].freeze

    # 支払いが通っていない状態（⚠ **拒否側**・2026-10-03）。`grace` は猶予、
    # `billing_retry` はストアが再試行中、`pending` は Google で支払い保留。
    #
    # ⚠ 理由を `no_entitlement` と分けるのは、**対処がまったく違う**から ——
    # こちらは「支払い方法を直せば戻る」。capsicum の登録ステータス画面
    # （capsicum#1123）がこの区別を出す。
    UNPAID_STATUSES = ['grace', 'billing_retry', 'pending'].freeze

    # 許可した / 拒んだ理由。metrics のラベルに出す。
    REASON_ENFORCE_OFF = 'enforce_off'.freeze
    REASON_PRESET = 'preset'.freeze
    # 非プリセットの行だが、**同じ端末にプリセットの購読がある**ので通した (#82)。
    #
    # ⚠ **`preset` と分ける。**こちらは「プリセットに 1 アカウント持てば全部無償」で
    # 無償になった外部サーバーの分で、**その量が見えなくなると、仕様の効き方を
    # 測れない**。
    REASON_PRESET_DEVICE = 'preset_device'.freeze
    REASON_ENTITLED = 'entitled'.freeze
    REASON_NO_ENTITLEMENT = 'no_entitlement'.freeze

    # 返金済みだが支払い済みの期間が残っているので通した (#63)。
    #
    # ⚠ **理由を分ける。**`entitled` に混ぜると、**実質無償で配信している量が
    # 見えなくなる**（返金で期限まで通す判断を見直したくなったときの材料）。
    REASON_ENTITLED_REFUNDED = 'entitled_refunded'.freeze

    # 支払いが通っていないので拒んだ（猶予・課金リトライ・支払い保留）(#63)。
    REASON_UNPAID = 'unpaid'.freeze

    # 期限が切れているので拒んだ (#63)。
    #
    # ⚠⚠ **`status` が `active` のままでもここに落ちる。**更新の通知を取りこぼすと
    # 行は `active` で残り続けるので、**`expires_at` を見ないと永久に通ってしまう**
    # （#63 本文の「通知だけに頼ると、取りこぼした購読が永久に有効なまま残る」）。
    REASON_EXPIRED = 'expired'.freeze

    # プリセットを名乗ったが、**その鍵が引けなかった** (#69)。⚠⚠ **fail-open で
    # 通す。**引けないのは**こちらの障害**（相手が落ちている・DNS・こちらの
    # 外向き通信）で、⚠ **本物のプリセットの通知を止めるほうが取り返しがつかない。**
    REASON_PRESET_UNVERIFIABLE = 'preset_unverifiable'.freeze
    # プリセットを名乗ったが、**署名が無い / 読めない** (#69)。⚠ 本物の
    # Mastodon / Misskey は必ず VAPID を付けるので、**プリセット扱いをやめる。**
    REASON_PRESET_UNSIGNED = 'preset_unsigned'.freeze
    # プリセットを名乗ったが、**そのホストの鍵ではない** (#69)。⚠⚠ **詐称。**
    REASON_PRESET_MISMATCH = 'preset_mismatch'.freeze
    # プリセットを名乗ったが、**裏取りが競合した** (#69・Codex P1 6 巡目)。
    #
    # ⚠⚠ **fail-open にしない。**畳むと、**同時リクエストを撃つだけで確定的に
    # ゲートを抜けられる** —— 1 本目が枠を取り、2 本目が「外部障害」として通る。
    # ⚠ **410 でもない**（購読が消える）。route が **503 で再試行させる。**
    REASON_PRESET_BUSY = 'preset_busy'.freeze

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
    PRESET_BUSY = :busy

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
    # ⚠ [now] はテストから固定するためだけのもの（既定は現在の UTC）。
    #
    # rubocop:disable Metrics/ParameterLists
    # ⚠ 6 個目は [now]。判定の入口を 1 本に保つほうが大事なので、ここは外す
    # （`announcement_worker` と同じ扱い）。
    def self.decide(subscription:, database:, preset_verification: PRESET_NOT_CHECKED,
      extra_preset_hosts: nil, env: ENV, now: Time.now.utc)
      # rubocop:enable Metrics/ParameterLists
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
        entitled, = entitlement_decision(database, subscription['device_id'], now: now)
        return [true, entitled] if entitled

        # ⚠ 理由は **`no_entitlement` ではなくプリセット側の失敗**を返す。
        # 「利用権が無い」と「プリセットを詐称した」は対処がまったく違う。
        return [false, reason]
      end
      # ⚠⚠ **購読 1 行の `server` だけで決めない (#82)。**クライアントは `server` に
      # そのアカウント自身のホストを送るので、行だけを見ると**プリセットと外部を
      # 併用する人の外部側が止まる** —— 仕様（全部無償）に反するうえ、その人の
      # 画面には課金の表示が出ない（capsicum#1123）ので**黙って通知が消える。**
      if preset_device?(database, subscription['device_id'], extra_preset_hosts)
        return [true, REASON_PRESET_DEVICE]
      end
      allowed_reason, denied_reason = entitlement_decision(
        database, subscription['device_id'], now: now
      )
      return [true, allowed_reason] if allowed_reason

      return [false, denied_reason]
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
      when PRESET_BUSY then return [false, REASON_PRESET_BUSY]
      else return [false, REASON_PRESET_UNSIGNED]
      end
    end

    # 端末の持つ購入を見て `[通した理由, 拒んだ理由]` を返す (#63)。
    # ⚠ **通ったときは 1 つ目だけが非 nil、拒んだときは 2 つ目だけが非 nil。**
    #
    # ⚠ **`device_id` が NULL の行（旧クライアント）は利用権を引けない**ので拒否。
    # 非プリセットの旧クライアントは、ゲートを閉じたときに止まる。
    # ⚠⚠ 実測では該当 0 人（設計書 1-2）だが、**閉じる前に測り直すこと。**
    #
    # ⚠⚠ **1 行でも通れば通す。**1 端末が複数の購入にぶら下がりうる（買い直し・
    # 別ストア）ので、**拒否の理由は「通る行が 1 つも無かった」ときだけ**意味を持つ。
    def self.entitlement_decision(database, device_id, now: Time.now.utc)
      return [nil, REASON_NO_ENTITLEMENT] if device_id.to_s.empty?

      denied = REASON_NO_ENTITLEMENT
      database.entitlement_tokens_for_device(device_id).each do |row|
        allowed, reason = row_decision(row, now: now)
        return [reason, nil] if allowed

        denied = reason if denial_rank(reason) > denial_rank(denied)
      end
      return [nil, denied]
    end

    # 1 行ぶんの判定。戻り値は `[許可か, 理由]`。
    def self.row_decision(row, now: Time.now.utc)
      status = row['status']
      expires_at = parse_store_time(row['expires_at'])
      # ⚠ 期限が読めない / 無いときは「残っている」とみなす（fail-open）。
      within = expires_at.nil? || expires_at > now
      return [true, REASON_ENTITLED] if ENTITLED_STATUSES.include?(status) && within
      # ⚠ 返金済みは期限まで通す（2026-10-03 判断）。
      # ⚠⚠ **ただし期限が読めるときだけ。**返金済みで期限が分からない行を fail-open に
      # すると「期限まで」が無期限になり、**実質無償が永久に続く**。有効な購入
      # （`active`）の fail-open とは**守りたいものが逆**なので、ここは揃えない。
      if REFUNDED_STATUSES.include?(status)
        return [true, REASON_ENTITLED_REFUNDED] if expires_at && expires_at > now

        return [false, REASON_EXPIRED]
      end
      # ⚠ 未払いは期限の内外を問わず拒む（猶予中は expires_at が過去にあるのが普通）。
      return [false, REASON_UNPAID] if UNPAID_STATUSES.include?(status)
      # ⚠⚠ **`active` のまま期限が過ぎている行はここに落ちる**（更新の通知を
      # 取りこぼした形）。`expired` も同じ理由へ寄せる。
      return [false, REASON_EXPIRED] if status == 'expired' || ENTITLED_STATUSES.include?(status)

      # `unverified` と、上流が増やした知らない状態。⚠ **勝手に通さない。**
      return [false, REASON_NO_ENTITLEMENT]
    end

    # 拒否理由の情報量の順位（複数行あるときに残す理由を選ぶ）。
    #
    # ⚠ **未払いを最優先で残す。**利用者が自分で直せる唯一の状態で、
    # capsicum の登録ステータス画面（capsicum#1123）が案内を出す対象。
    def self.denial_rank(reason)
      case reason
      when REASON_UNPAID then return 2
      when REASON_EXPIRED then return 1
      else return 0
      end
    end

    # 支払い済みの期間が残っているか。
    #
    # ⚠⚠ **読めない / 無い値は「残っている」とみなす（fail-open）。**期限が分から
    # ないことを理由に止めると、**ストアの応答の形が変わっただけで配信が落ちる**。
    # ⚠ 代わりに、期限の読めない行は確かめ直しの対象になる（[EntitlementReverifier]）。
    def self.within_period?(expires_at, now: Time.now.utc)
      parsed = parse_store_time(expires_at)
      return true unless parsed

      return parsed > now
    end

    # ストアが入れた時刻文字列を Time へ。読めなければ nil。
    #
    # ⚠⚠ **帯の無い文字列をそのまま `Time.parse` に渡さない。**ローカル時刻として
    # 読まれる。`app_store_client` / `google_play_client` が入れるのは **UTC の
    # `%Y-%m-%d %H:%M:%S`** なので、帯が無ければ UTC を明示する。
    def self.parse_store_time(value)
      text = value.to_s.strip
      return nil if text.empty?
      return Time.parse(text) if text.match?(/[Zz]\z|[+-]\d{2}:?\d{2}\z/)

      return Time.parse("#{text} UTC")
    rescue ArgumentError
      return nil
    end

    # 同じ端末にプリセットを名乗る購読があるか (#82)。
    #
    # ⚠⚠ **名乗りは申告のまま認める（2026-10-03 pooza 判断）。**VAPID の裏取り（#69）を
    # 条件にすると、**プリセットのアカウントにほとんど通知が来ない人**は裏が取れず、
    # 外部の通知を黙って失う。偽装による迂回は許すことになるが、⚠ **プリセットの行
    # そのものへの push の裏取り（#69）はそのまま効く**（[preset_decision]）。
    #
    # ⚠ **`device_id` が無い行（旧クライアント）は端末をまたいで束ねられない**ので false。
    def self.preset_device?(database, device_id, extra_preset_hosts)
      return false if device_id.to_s.empty?

      return database.servers_for_device(device_id).any? do |server|
        Relay::PresetServers.preset?(server, extra: extra_preset_hosts)
      end
    end
  end
end
