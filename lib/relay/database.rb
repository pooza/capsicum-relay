require 'logger'
require 'securerandom'
require 'sqlite3'
require_relative 'serialized_connection'

module Relay
  # スキーマ定義と移行 (device_type の macos #468 / windows #474 追加、FK 修復な
  # ど) を全部抱えているため長い。恒久的には migration の module 抽出が本筋だが、
  # 当面は Metrics/ClassLength をここだけ落として許容する。
  class Database # rubocop:disable Metrics/ClassLength
    DB_PATH = File.expand_path('../../db/relay.sqlite3', __dir__)

    # テーブル組み替え (rebuild_with_all_rows!) でコピーする列。実際には旧テーブル
    # に実在するものだけに絞る。device_id (#15) は ALTER で後付けされるため、組み
    # 替えが走る時点で有る場合と無い場合があり、固定リストで書くとどちらかで壊れる
    # （無い列を SELECT すれば SQLException、有る列を落とせば device_id が黙って
    # 消えて dedup が失われる）。
    COPYABLE_SUBSCRIPTION_COLUMNS = [
      'id', 'token', 'push_token', 'device_type', 'account', 'server',
      'device_id', 'created_at', 'updated_at'
    ].freeze

    # 利用権を扱えるストア (capsicum#597 / #58)。⚠ **Linux は入れない**
    # （買える経路が無い・設計書の未決事項 7）。
    ENTITLEMENT_STORES = ['apple', 'google', 'microsoft'].freeze

    # ストアで確かめた購入の状態 (#61)。[apply_entitlement_verification] に渡す。
    EntitlementVerification = Struct.new(
      :store, :purchase_id, :product_id, :status, :expires_at, :environment, :signed_at,
      keyword_init: true
    )

    # 検証していない購入 (#58)。⚠⚠ **ゲート (#60) の許可側へ入れてはいけない。**
    ENTITLEMENT_STATUS_UNVERIFIED = 'unverified'.freeze

    # 購入の状態 (#58)。⚠ **DB の CHECK ではなくここで検査する**（理由は
    # [create_entitlement_tables!] の doc）。フェーズ 3（#63）で増える。
    #
    # `billing_retry` は #61 で足した（ストアが支払いを再試行している間・拒否側）。
    # `pending` は #62 で足した（Google で支払いが保留中・まだ払われていない・拒否側）。
    ENTITLEMENT_STATUSES = [
      ENTITLEMENT_STATUS_UNVERIFIED, 'active', 'grace', 'billing_retry', 'pending', 'expired',
      'revoked'
    ].freeze

    # device_id を持たない古い行を掃除してよいと判断するまでの猶予 (capsicum#949)。
    # 生きている端末は起動のたびに register して updated_at が進むので、これを
    # 超えるのは実際に使われていない行だけになる。詳細は purge_legacy_rows 参照。
    LEGACY_ROW_GRACE_DAYS = 14

    # [path] は開く DB ファイル。省略時は [DB_PATH]（既定の評価は呼び出し時
    # なので、既存テストの `const_set(:DB_PATH, ...)` 差し替えも従来どおり効く）。
    #
    # ⚠ **env をここで読まない。** 「どのテストが先に require したか」で本番 DB を
    # 掴む形になりうる。テスト用の差し替えは呼び出し側（App）が明示的に渡す (#34)。
    def initialize(logger: Logger.new($stdout), path: DB_PATH)
      @logger = logger
      # ⚠ **スレッド間で直列にした接続**（理由は [Relay::SerializedConnection]）。
      @db = Relay::SerializedConnection.new(SQLite3::Database.new(path))
      @db.results_as_hash = true
      @db.execute('PRAGMA journal_mode=WAL')
      @db.execute('PRAGMA foreign_keys=ON')
      migrate!
    end

    # Subscription は (token, account, server) 単位で 1 行。同一端末に複数
    # アカウントを登録した場合は各アカウントに独立した row と push_token が
    # 割り当てられる。push_token 生成は新規 INSERT 時のみで、既存行の再登録
    # では push_token を維持する（Mastodon / Misskey 側の subscription endpoint
    # との整合を保つため）。
    #
    # [device_id] はクライアントがインストール単位で持つ安定 ID (capsicum#932)。
    # 渡された場合は **(account, server, device_id) をキーに upsert** し、
    # トークンが更新されても行を増やさず token を差し替える。これがないと
    # 「push トークン更新 → 新しい行 → 旧行が孤児化 → 二重 push」が積み上がる
    # (#15)。渡されない（旧クライアント）場合は従来どおり token をキーにする。
    def register(token:, device_type:, account:, server:, device_id: nil)
      device_id = nil if device_id.to_s.empty?
      return register_by_token(token, device_type, account, server) unless device_id

      row = adoptable_row(token, account, server, device_id)
      current = if row
        update_registration(row, token, device_type, device_id)
      else
        insert_registration(token, device_type, account, server, device_id)
        find_by_composite(token, account, server)
      end
      purge_legacy_rows(account, server, device_type, current['id'])
      return current
    end

    def unregister(id)
      sub = find(id)
      return nil unless sub

      @db.execute('DELETE FROM subscriptions WHERE id = ?', [id])
      return sub
    end

    # 配送が恒久的に失敗した購読を落とす (#55 / PR #67 の Codex P1)。
    #
    # ⚠⚠ **行 ID だけで消してはいけない。**[update_registration] は**行 ID を保ったまま
    # `token` を差し替える**（#15 の dedup のため）。配送をキューに積んでから結末が
    # 出るまでの間に `/register` で端末のトークンが更新されると、⚠ **いま有効な
    # 登録を消してしまう** —— `announcement_subscriptions` も FK の CASCADE で消え、
    # 上流は次の push で 410 を受けて購読を掃除する ＝ **利用者は再登録まで通知を
    # 失う。**
    #
    # ⚠ **同期配送のときも同じ race があった**が、窓がリクエストの中（〜2 秒）に
    # 限られていた。#55 でキューの待ち時間ぶん窓が広がったので、条件を付ける。
    #
    # [token] は**配送を積んだ時点の**端末トークン。消えたら行を返し、
    # 差し替わっていたら nil を返す（＝消さなかった）。
    def unregister_stale(id, token)
      sub = find(id)
      return nil unless sub
      return nil unless sub['token'] == token

      @db.execute(
        'DELETE FROM subscriptions WHERE id = ? AND token = ?', [id, token]
      )
      return sub
    end

    def find(id)
      return @db.execute('SELECT * FROM subscriptions WHERE id = ?', [id]).first
    end

    def find_by_composite(token, account, server)
      return @db.execute(
        'SELECT * FROM subscriptions WHERE token = ? AND account = ? AND server = ?',
        [token, account, server],
      ).first
    end

    # インストール単位の device_id で引く (#15)。(account, server, device_id) は
    # 部分 UNIQUE インデックスで一意。
    def find_by_device(account, server, device_id)
      return @db.execute(
        'SELECT * FROM subscriptions WHERE account = ? AND server = ? AND device_id = ?',
        [account, server, device_id],
      ).first
    end

    def find_by_push_token(push_token)
      return @db.execute('SELECT * FROM subscriptions WHERE push_token = ?', [push_token]).first
    end

    def update_push_token(id, push_token)
      return @db.execute(<<~SQL, [push_token, id])
        UPDATE subscriptions SET push_token = ?, updated_at = datetime('now') WHERE id = ?
      SQL
    end

    def count
      return @db.get_first_value('SELECT COUNT(*) FROM subscriptions')
    end

    # お知らせ通知 (announcement push) の subscription 管理。capsicum#477 /
    # capsicum-relay#14。subscriptions と外部キーで紐付き、subscription 解除
    # 時にカスケード削除される。
    def register_announcement_subscription(push_token:, server:, account:)
      @db.execute(<<~SQL, [push_token, server, account])
        INSERT INTO announcement_subscriptions
          (push_token, server, account, created_at, updated_at)
        VALUES (?, ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(push_token, server, account) DO UPDATE SET
          updated_at = datetime('now')
      SQL
      return find_announcement_subscription_by_composite(push_token, server, account)
    end

    def unregister_announcement_subscription(id)
      sub = find_announcement_subscription(id)
      return nil unless sub

      @db.execute('DELETE FROM announcement_subscriptions WHERE id = ?', [id])
      return sub
    end

    def find_announcement_subscription(id)
      return @db.execute(
        'SELECT * FROM announcement_subscriptions WHERE id = ?', [id]
      ).first
    end

    def find_announcement_subscription_by_composite(push_token, server, account)
      return @db.execute(<<~SQL, [push_token, server, account]).first
        SELECT * FROM announcement_subscriptions
        WHERE push_token = ? AND server = ? AND account = ?
      SQL
    end

    def find_announcement_subscriptions_by_push_token(push_token)
      return @db.execute(
        'SELECT * FROM announcement_subscriptions WHERE push_token = ?',
        [push_token],
      )
    end

    def announcement_subscription_count
      return @db.get_first_value('SELECT COUNT(*) FROM announcement_subscriptions')
    end

    # announcement polling worker (capsicum-relay#14 Phase 2) 用。subscription が
    # 1 件でもある server のみ poll 対象にする。
    def announcement_servers
      return @db.execute(<<~SQL).map {|row| row['server']}
        SELECT DISTINCT server FROM announcement_subscriptions
      SQL
    end

    # server に紐づく subscription を、push 発火に必要な device_type / token と
    # 一緒に取得する (subscriptions を JOIN)。
    def announcement_subscriptions_for_server(server)
      return @db.execute(<<~SQL, [server])
        SELECT a.id AS announcement_subscription_id, a.server, a.account,
               s.id AS subscription_id, s.token, s.device_type, s.push_token
        FROM announcement_subscriptions a
        JOIN subscriptions s ON a.push_token = s.push_token
        WHERE a.server = ?
      SQL
    end

    # サポーター状態 (capsicum#596 / #18)。(account, server) 単位で 1 行。
    # subscriptions とは独立（push 未登録の端末からも投げ銭は成立する）。
    # tip_count は複数端末の合算で、再送による多少の過大計上を許容する近似値。
    # バッジ判定は first_tipped_at の有無のみで行う。
    def record_supporter_tip(account:, server:, sku: nil, tipped_at: nil, count: 1)
      # tipped_at は ISO8601 を datetime() で正規化して保存する。
      # datetime('now') と同じ 'YYYY-MM-DD HH:MM:SS' 形式に揃えないと、
      # upsert の MIN() が文字列比較で破綻する。
      @db.execute(<<~SQL, [account, server, tipped_at, count, sku])
        INSERT INTO supporters
          (account, server, first_tipped_at, tip_count, last_sku, created_at, updated_at)
        VALUES (?, ?, COALESCE(datetime(?), datetime('now')), ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(account, server) DO UPDATE SET
          first_tipped_at = MIN(first_tipped_at, excluded.first_tipped_at),
          tip_count = tip_count + excluded.tip_count,
          last_sku = COALESCE(excluded.last_sku, last_sku),
          updated_at = datetime('now')
      SQL
      return find_supporter(account: account, server: server)
    end

    def find_supporter(account:, server:)
      return @db.execute(
        'SELECT * FROM supporters WHERE account = ? AND server = ?',
        [account, server],
      ).first
    end

    def supporter_count
      return @db.get_first_value('SELECT COUNT(*) FROM supporters')
    end

    # 有償リレーの利用権 (capsicum#597 / #58)。**購入**単位。
    #
    # ⚠⚠ **フェーズ 1 ではレシートを検証しない**（検証はフェーズ 3 / #61 / #62）。
    # 新規の status は必ず [ENTITLEMENT_STATUS_UNVERIFIED] で、**「購入した証拠」
    # ではない**。⚠ ゲート (#60) を実際に閉じるときに `unverified` を許可側へ
    # 入れてはいけない —— このエンドポイントは共有シークレットしか見ておらず、
    # **シークレットはバイナリから取り出せる**（capsicum#1121）ので、誰でも
    # 好きな `purchase_id` で行を作れる。
    #
    # [device_id] は `subscriptions.device_id` と同じ、クライアントがインストール
    # 単位で持つ安定 ID (#15 / capsicum#932)。⚠ **新しい識別子を作らない**（#57）。
    #
    # 同じ (store, purchase_id, device_id) で二度呼ばれたら**同じ token を返す**。
    # ⚠ アプリの起動ごとに token が増えると、端末単位の無効化 (#57) が
    # 「どれを消せばいいのか分からない」状態になる。
    #
    # ⚠ **行を作ってから token を入れるまでを 1 つのトランザクションにする**（Codex P2・
    # PR #75）。間に検証の付け替え（[apply_entitlement_verification]）が割り込むと、
    # 作ったばかりの行が消され、消えた行を指す token を入れようとして外部キー違反で落ちる。
    # トランザクションの間は [Relay::SerializedConnection] がほかのスレッドを待たせる。
    def issue_entitlement_token(store:, purchase_id:, device_id:, product_id: nil)
      @db.transaction do
        entitlement = upsert_entitlement(store, purchase_id, product_id)
        upsert_entitlement_token(entitlement['id'], device_id)
        return find_entitlement_token_by_device(entitlement['id'], device_id)
      end
    end

    # token 1 本を、紐づく購入の状態と一緒に引く (#58)。ゲート (#60) の入口。
    #
    # ⚠ **返すのは join 済みの 1 行。**`status` / `expires_at` は購入側の列で、
    # token 側には無い（端末ごとに状態が分かれることは無い）。
    def find_entitlement_token(token)
      return @db.execute(<<~SQL, [token]).first
        SELECT t.id, t.token, t.entitlement_id, t.device_id,
               t.created_at, t.updated_at,
               e.store, e.purchase_id, e.product_id, e.status, e.expires_at, e.environment
        FROM entitlement_tokens t
        JOIN entitlements e ON t.entitlement_id = e.id
        WHERE t.token = ?
      SQL
    end

    # `subscriptions.device_id` から利用権を引く (#57 の 2-4 の経路)。
    #
    # ⚠ **1 端末が複数の購入にぶら下がりうる**（買い直し・別ストア）。ゲートは
    # 「1 つでも有効なものがあるか」で見るので、**全部返す**。
    def entitlement_tokens_for_device(device_id)
      return [] if device_id.to_s.empty?

      return @db.execute(<<~SQL, [device_id])
        SELECT t.token, t.device_id, e.store, e.purchase_id, e.status, e.expires_at
        FROM entitlement_tokens t
        JOIN entitlements e ON t.entitlement_id = e.id
        WHERE t.device_id = ?
      SQL
    end

    # 同じ端末が登録しているサーバー (capsicum-relay#82)。
    #
    # ⚠ **プリセットかどうかはここで判定しない。**表記の揺れ（大小・末尾のドット）を
    # 揃えるのは [Relay::PresetServers.preset?] の仕事で、SQL で比べると揺れた行を
    # 取りこぼす。
    def servers_for_device(device_id)
      return [] if device_id.to_s.empty?

      return @db.execute(
        'SELECT DISTINCT server FROM subscriptions WHERE device_id = ?', [device_id]
      ).map {|row| row['server']}
    end

    # 1 購入にぶら下がっている端末 (#58)。
    #
    # ⚠ **上限は設けない**（#57）。対象者 0 人から始まるので先回りで制限せず、
    # **件数だけ記録する**。異常な数が出てから考える。
    def entitlement_tokens_for_purchase(store, purchase_id)
      return @db.execute(<<~SQL, [store, purchase_id])
        SELECT t.token, t.device_id, t.created_at
        FROM entitlement_tokens t
        JOIN entitlements e ON t.entitlement_id = e.id
        WHERE e.store = ? AND e.purchase_id = ?
      SQL
    end

    def entitlement_count
      return @db.get_first_value('SELECT COUNT(*) FROM entitlements')
    end

    def find_entitlement(store, purchase_id)
      return @db.execute(
        'SELECT * FROM entitlements WHERE store = ? AND purchase_id = ?',
        [store, purchase_id],
      ).first
    end

    # ストアで検証した結果を購入の行へ反映する (#61)。反映先の行 id を返す。
    #
    # ⚠⚠ **`purchase_id` を元の取引 ID（originalTransactionId）へ付け替える。**
    # クライアントが送ってくるのは StoreKit の transactionId で、**更新のたびに
    # 変わる**。そのまま持つと、同じサブスクが更新ごとに別の行になる（通知は
    # 元の取引 ID で来るので、どの行を更新すべきかも引けない）。
    #
    # 付け替え先の行が既にあるとき（別の端末が先に検証した・更新後の取引 ID で
    # 送り直した）は、**端末の token をそちらへ寄せてから元の行を消す**。
    # ⚠ 寄せる先に同じ端末の token が既にあれば、そちらを残す
    # （`UNIQUE(entitlement_id, device_id)`）。クライアントには応答で新しい token を
    # 返すので、手元の token が変わっても追いつく。
    # [verification] は [EntitlementVerification]。
    def apply_entitlement_verification(entitlement_id, verification)
      @db.transaction do
        target = find_entitlement(verification.store, verification.purchase_id)
        if target && target['id'] != entitlement_id
          merge_entitlement_tokens!(entitlement_id, target['id'])
          @db.execute('DELETE FROM entitlements WHERE id = ?', [entitlement_id])
          entitlement_id = target['id']
        end
        update_entitlement_verification!(entitlement_id, verification)
      end
      return entitlement_id
    end

    # 確かめ直す `unverified` の購入 (Codex P1・PR #75)。**作られてから [days] 日以内**で、
    # 最後に触ってから時間の経ったものから [limit] 件。
    #
    # ⚠ `unverified` の行は誰でも作れる（`POST /entitlements` は共有シークレットだけ）。
    # **件数と期間で縛る**のは、でたらめな行を大量に作られても Apple API を叩く量が
    # 増えないようにするため。
    # ⚠ [grace] / [backoff_days] は「知らない」と言われ続けている行の間隔
    # （[not_found_backoff_sql] の doc）。
    #
    # ⚠⚠ **連続が始まっている行は、作成の窓を過ぎても引き続き引く**（PR #86 の Codex P2）。
    # そうしないと **約束した終端（`revoked`）に永久に到達しない** —— `not_found_since` が
    # 立つのは最初の掃除（作成 + 数分）なので、`created_at` 基準の窓（[days] 日）が
    # [record_entitlement_not_found] の終端（同じ 7 日）より**必ず先に閉じる**。
    #
    # ⚠ **叩く量は増えない。**連続が猶予を越えた行はバックオフで 1 日 1 回に落ち、
    # 7 日で `revoked` になって `status` の条件から外れる ＝ **1 行あたり 10 回前後で打ち止め**
    # （直す前は 7 日間 10 分ごと ＝ 1,000 回超だった）。
    def unverified_entitlements(store, days:, limit:, grace:, backoff_days:)
      window = "-#{Integer(days)} days"
      values = [store, ENTITLEMENT_STATUS_UNVERIFIED, window, grace,
        "-#{Integer(backoff_days)} days", limit]
      return @db.execute(<<~SQL, values)
        SELECT * FROM entitlements
        WHERE store = ? AND status = ?
          AND (created_at >= datetime('now', ?) OR not_found_since IS NOT NULL)
          AND #{not_found_backoff_sql}
        ORDER BY updated_at ASC, id ASC
        LIMIT ?
      SQL
    end

    # 「知らない」と言われ続けている行を毎周引かないための条件 (#63)。
    #
    # ⚠⚠ **最初の [grace] 回は素通りさせる**（＝従来どおり毎周引く）。買った直後は
    # ストアへの伝播が遅れていることがあり、その行は `unverified` のままで
    # **ゲートが deny する**。自動で治す経路はこの掃除だけなので（クライアントは
    # 起動時に `POST /entitlements` を送り直さず、持っている token で読むだけ）、
    # **最初から 1 日待たせると買った人が最大 1 日使えない。**
    #
    # ⚠ 猶予を使い切った行は `updated_at` が [backoff_days] 日より古いときだけ引く。
    def not_found_backoff_sql
      return "(not_found_streak < ? OR updated_at <= datetime('now', ?))"
    end

    # 確かめ直す「検証は済んでいるが、いまの状態を信用できない」購入 (#63)。
    #
    # ⚠⚠ **通知は落ちる。**Apple の V2 / Google の RTDN を取りこぼすと、行は更新前の
    # 状態で残り続ける —— ⚠ **更新を取りこぼした `active` は期限が過ぎても `active`**
    # で、ゲートが `expires_at` を見るようになった（#63）とはいえ、**本当は払われて
    # いる購読を止めてしまう**。逆に失効を取りこぼせば通し続ける。**どちらも通知
    # 任せでは直らない**ので、ここで引き直す。
    #
    # 引くのは次のどれかに当たる行:
    #
    # - `expires_at` が過ぎている（更新か失効のどちらかが起きているはず）
    # - `expires_at` が無い（⚠ ゲートが fail-open で通す側なので、放置できない）
    # - 最後に触ってから [stale_days] 日より長く動いていない（通知の取りこぼしの保険）
    #
    # ⚠ **終端の状態（`expired` / `revoked`）は引かない。**変化するのは利用者が
    # 買い直したときで、そのときは**クライアント自身の `POST /entitlements` が
    # その場で確かめる**（あの口はストアを引く）。ここで追い続けると、終わった購入に
    # 永久に API を叩くことになる。
    #
    # ⚠ `unverified` は [unverified_entitlements] の担当（あちらは誰でも作れる行なので
    # 期間と件数の縛りが違う）。
    def stale_entitlements(store, limit:, stale_days:, grace:, backoff_days:)
      window = "-#{Integer(stale_days)} days"
      skipped = [ENTITLEMENT_STATUS_UNVERIFIED, 'expired', 'revoked']
      values = [store, *skipped, window, grace, "-#{Integer(backoff_days)} days", limit]
      return @db.execute(<<~SQL, values)
        SELECT * FROM entitlements
        WHERE store = ? AND status NOT IN (?, ?, ?)
          AND (expires_at IS NULL OR expires_at = ''
               OR expires_at <= datetime('now')
               OR updated_at <= datetime('now', ?))
          AND #{not_found_backoff_sql}
        ORDER BY updated_at ASC, id ASC
        LIMIT ?
      SQL
    end

    # ストアが「その購入は知らない」と答えたことを記録する (#63)。
    #
    # ⚠⚠ **[terminal_days] 日続いたら終端（`revoked`）へ落とす。**ゲートは期限の
    # 読めない `active` を fail-open で通すので、放置すると「**ストアが知らない購入が
    # 無期限に通る**」行が残る。終端にすれば [stale_entitlements] の除外にも入り、
    # 掃除が止まる。
    #
    # ⚠ **「届かない」（`unavailable`）では呼ばない。**あちらはストア障害で、
    # 有効な購読を失効させてはいけない（呼び出し側 [Relay::EntitlementReverifier] で分岐）。
    def record_entitlement_not_found(entitlement_id, terminal_days:)
      window = "-#{Integer(terminal_days)} days"
      @db.transaction do
        @db.execute(<<~SQL, [entitlement_id])
          UPDATE entitlements SET
            not_found_streak = not_found_streak + 1,
            not_found_since = COALESCE(not_found_since, datetime('now')),
            updated_at = datetime('now')
          WHERE id = ?
        SQL
        @db.execute(<<~SQL, [entitlement_id, window])
          UPDATE entitlements SET status = 'revoked', updated_at = datetime('now')
          WHERE id = ? AND not_found_since IS NOT NULL AND not_found_since <= datetime('now', ?)
        SQL
      end
    end

    # 確かめ直した行を順番の後ろへ回す（同じ行ばかり引かないように）。
    def touch_entitlement(entitlement_id)
      @db.execute("UPDATE entitlements SET updated_at = datetime('now') WHERE id = ?",
        [entitlement_id])
    end

    # 端末の token を、購入の行 id と端末 id から引く（検証で行が寄った後に
    # クライアントへ返し直すため）。
    def entitlement_token_for(entitlement_id, device_id)
      return find_entitlement_token_by_device(entitlement_id, device_id)
    end

    def entitlement_token_count
      return @db.get_first_value('SELECT COUNT(*) FROM entitlement_tokens')
    end

    def announcement_seen?(server, announcement_id)
      return @db.get_first_value(<<~SQL, [server, announcement_id.to_s]).to_i.positive?
        SELECT COUNT(*) FROM seen_announcements
        WHERE server = ? AND announcement_id = ?
      SQL
    end

    def mark_announcement_seen(server, announcement_id)
      @db.execute(<<~SQL, [server, announcement_id.to_s])
        INSERT OR IGNORE INTO seen_announcements (server, announcement_id, seen_at)
        VALUES (?, ?, datetime('now'))
      SQL
    end

    private

    # device_id を送らない旧クライアント向けの従来経路。(token, account, server)
    # をキーにした upsert で、トークンが変われば別の行になる。
    def register_by_token(token, device_type, account, server)
      push_token = SecureRandom.hex(32)
      @db.execute(<<~SQL, [token, push_token, device_type, account, server])
        INSERT INTO subscriptions (token, push_token, device_type, account, server, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(token, account, server) DO UPDATE SET
          device_type = excluded.device_type,
          updated_at = datetime('now')
      SQL
      return find_by_composite(token, account, server)
    end

    # device_id 付き register が上書きすべき既存行を決める。**この順序に意味が
    # ある**（どちらの制約にも触れずに済む唯一の順序）:
    #
    # 1. **今のトークンを持つ行**があればそれ。上流 (Mastodon / Misskey) が現に
    #    push している行なので、push_token を保ったまま device_id を埋める。
    #    トークンを書き換えないので UNIQUE(token, account, server) に触れない。
    #    同じ device_id を持つ別行があれば、それは同一インストールの古い孤児
    #    なので畳む（部分 UNIQUE インデックスを守るためにも必要）。
    # 2. なければ**同じ device_id の行**。これがトークン更新のケースで、行を
    #    増やさず token だけ差し替える。1 で外れている = その (token, account,
    #    server) を持つ行は無いので、やはり衝突しない。
    # 3. どちらも無ければ新規 INSERT（呼び出し側）。
    #
    # 1 と 2 が別の行を指すのは、トークンが一度離れて戻る場合だけで実運用では
    # 起きない（APNs / FCM トークンも WNS Channel URI も巻き戻らない）。部分
    # UNIQUE インデックスを違反させないための防御として畳んでおく。畳んだ行の
    # announcement_subscriptions は FK の CASCADE で一緒に消える。
    def adoptable_row(token, account, server, device_id)
      by_token = find_by_composite(token, account, server)
      by_device = find_by_device(account, server, device_id)
      return by_device unless by_token
      return by_token if by_device.nil? || by_token['id'] == by_device['id']

      @logger.info(
        "Collapsing orphaned subscription id=#{by_device['id']} into" \
          " id=#{by_token['id']} (#{account}@#{server})",
      )
      @db.execute('DELETE FROM subscriptions WHERE id = ?', [by_device['id']])
      return by_token
    end

    # device_id を持たない古い行のうち、**同じ端末の旧版が残したもの**を掃除する
    # (capsicum#949)。
    #
    # device_id 導入前 (capsicum#932 以前) のクライアントは、push トークンが変わる
    # たびに新しい行を作っていた。その行は上流 (Mastodon / Misskey) の購読が生きて
    # いる限り push され続けるため、**1 通の通知が行数ぶん増殖する**。2026-08-10 に
    # 実機で確認した例では windows 3 行 = 3 通で、行を消したら 1 通に戻った。
    #
    # 消す条件は 3 つ揃ったときだけ:
    #
    # 1. `device_id` が無い（＝旧版が作った行）
    # 2. 同じ (account, server, device_type) に **device_id 付きの行が既にある**
    #    ＝そのインストールは新版へ更新済みで、この行はもう誰も更新しない
    # 3. [LEGACY_ROW_GRACE_DAYS] 以上更新されていない
    #
    # 3 が要るのは、**同じ OS の別の実機がまだ旧版で動いている**場合を巻き込まない
    # ため。生きている端末は起動のたびに register して updated_at が進むので、
    # 猶予を超えるのは実際に使われていない行だけになる。仮に巻き込んでも、その端末
    # は次の起動で再登録されるので自己修復する（起動までの間だけ不達）。
    #
    # 上流の購読は消さない（消せない）が、行が無くなれば `/push/{push_token}` が
    # 410 Gone を返し、上流がその購読を破棄する（app.rb 参照）。カスケードで消える。
    #
    # クライアントは起動ごとに register するので、専用のスイープ機構は置かない。
    # 使われているインストールから順に、自然に掃除されていく。
    def purge_legacy_rows(account, server, device_type, keep_id)
      grace = "-#{LEGACY_ROW_GRACE_DAYS} days"
      stale = @db.execute(<<~SQL, [account, server, device_type, keep_id, grace])
        SELECT id, updated_at FROM subscriptions
        WHERE account = ? AND server = ? AND device_type = ?
          AND device_id IS NULL
          AND id != ?
          AND updated_at < datetime('now', ?)
      SQL
      return if stale.empty?

      stale.each do |row|
        @logger.info(
          "Purging legacy subscription id=#{row['id']} (#{account}/#{device_type}," \
            " last seen #{row['updated_at']})",
        )
        @db.execute('DELETE FROM subscriptions WHERE id = ?', [row['id']])
      end
    end

    # push_token は維持する。上流に登録済みの endpoint (/push/{push_token}) が
    # 変わると、その購読が宙に浮いて再登録されるまで不達になるため。
    def update_registration(row, token, device_type, device_id)
      @db.execute(<<~SQL, [token, device_type, device_id, row['id']])
        UPDATE subscriptions
        SET token = ?, device_type = ?, device_id = ?, updated_at = datetime('now')
        WHERE id = ?
      SQL
      return find(row['id'])
    end

    def insert_registration(token, device_type, account, server, device_id)
      @db.execute(<<~SQL, [token, SecureRandom.hex(32), device_type, account, server, device_id])
        INSERT INTO subscriptions
          (token, push_token, device_type, account, server, device_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
      SQL
    end

    def migrate!
      existing = subscriptions_schema
      if existing.nil?
        create_subscriptions_table!
      else
        migrate_subscriptions!(existing)
      end

      create_subscriptions_indexes!
      create_announcement_tables!
      create_supporters_table!
      create_entitlement_tables!
    end

    def create_subscriptions_indexes!
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_subscriptions_push_token
        ON subscriptions(push_token)
      SQL
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_subscriptions_token
        ON subscriptions(token)
      SQL
      # device-id dedup の実質的な UNIQUE 制約 (#15)。SQLite はテーブル制約に
      # WHERE を書けないので部分インデックスで張る。device_id を送らない旧
      # クライアントの行は全て NULL で、NULL 同士は UNIQUE でも衝突しないが、
      # 「旧クライアントは対象外」という意図を明示するため WHERE を書く。
      @db.execute(<<~SQL)
        CREATE UNIQUE INDEX IF NOT EXISTS idx_subscriptions_device
        ON subscriptions(account, server, device_id)
        WHERE device_id IS NOT NULL
      SQL
      # 端末単位で購読先を引く (#82・PR #83 の Codex P1)。⚠ **上の
      # `idx_subscriptions_device` は `account` が先頭なので device_id で引けない。**
      # enforce 中は非プリセットの `/push` が毎回ここを通り、DB アクセスは直列化
      # されているので、全件走査だと購読の総数に比例して無関係な要求まで待たせる。
      # ⚠ `server` まで含めて索引だけで答えられるようにする。
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_subscriptions_device_id
        ON subscriptions(device_id, server)
        WHERE device_id IS NOT NULL
      SQL
    end

    def subscriptions_schema
      return @db.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'subscriptions'",
      ).first
    end

    # 既存 subscriptions テーブルへの段階的スキーマ移行。SQLite は UNIQUE / CHECK
    # の ALTER ができないため、各移行はテーブル組み替え (rebuild_subscriptions_table!)
    # で行う。各 migrate_* はスキーマを読み直してから走らせ、前段の組み替えが
    # 最新スキーマを生成済みなら二重実行しない。
    def migrate_subscriptions!(existing)
      unless existing['sql'].include?('UNIQUE(token, account, server)')
        # 旧スキーマ（UNIQUE(token) 単独）からの移行。1 デバイス = 1 行の
        # 前提が崩れて N アカウント対応できないため、subscription-scoped に
        # 組み替える。pooza/capsicum-relay#3。
        migrate_to_subscription_scoped!
      end
      # device_type CHECK の enum 追加 (#468 macos / #474 windows)。最新スキーマで
      # 作り直して全行コピー。前段が最新を生成済みならスキーマ判定で skip。
      rebuild_with_all_rows! unless subscriptions_schema['sql'].include?("'macos'")
      rebuild_with_all_rows! unless subscriptions_schema['sql'].include?("'windows'")
      # client 由来の安定 device-id (#15 / capsicum#932)。nullable な列の追加
      # だけなのでテーブル組み替えは要らない。既存行は NULL のまま残り、次回の
      # register で埋まる。
      return if subscriptions_schema['sql'].include?('device_id')
      @db.execute('ALTER TABLE subscriptions ADD COLUMN device_id TEXT')
    end

    # 有償リレーの利用権 (capsicum#597 / #58)。テーブルは 2 本（#57 の決着）。
    #
    # ⚠⚠ **`subscriptions` に列を足さない。**あのテーブルは CHECK / UNIQUE を
    # 変えるたびに [rebuild_subscriptions_table!] が要り、**その組み替えは過去に
    # 子テーブルの FK を壊している**（`repair_announcement_subscriptions_fk!` が
    # 今も居座っているのがその跡・capsicum#468）。**課金の都合で push の中核
    # テーブルを組み替えない。**紐づけは `device_id` の join で足りる。
    #
    # ⚠⚠ **`status` に CHECK を付けない。**フェーズ 3（#63）で扱う状態は
    # 更新・失効・返金・支払い猶予・課金リトライと**これから増える**。CHECK を
    # 付けると状態を 1 つ足すたびにテーブル組み替えになり、`subscriptions` で
    # 踏んだのと同じ罠を新しいテーブルで再現することになる。値の検査は Ruby 側
    # （[ENTITLEMENT_STATUSES]）で行う。
    def create_entitlement_tables!
      create_entitlements_table!
      create_entitlement_tokens_table!
      # どの環境の API で確かめたか (#61)。`Production` / `Sandbox`。⚠ 本番 relay でも
      # TestFlight の購入は `Sandbox` になる（テスターを外へ広げるときに拒否側へ
      # 切り替えるための印・capsicum の paid-relay-plan.md 7-2）。nullable な列の
      # 追加だけなので組み替えは要らない。
      columns = table_columns('entitlements')
      unless columns.include?('environment')
        @db.execute('ALTER TABLE entitlements ADD COLUMN environment TEXT')
      end
      # 反映した結果にストアが署名した時刻（ミリ秒）(Codex P2・PR #75)。古い結果での
      # 上書きを拒むための順序。
      unless columns.include?('signed_at')
        @db.execute('ALTER TABLE entitlements ADD COLUMN signed_at INTEGER')
      end
      add_not_found_columns!(columns)
    end

    # ストアが「その購入は知らない」と言い続けている行を数える 2 列 (#63)。
    #
    # ⚠⚠ **これが無いと掃除が永久に回る。**`not_found` は行を触らない（fail-open の
    # 一種）ので、**終端にも落ちず、掃除の除外にも入らない** —— ステージングでは
    # 行 3 つに対して not_found が 694 回出ていた（2026-10-05 実測）。
    #
    # - `not_found_streak`: 連続で「知らない」と言われた回数。⚠ ストアが答えたら 0 に戻す
    #   （[update_entitlement_verification!]）
    # - `not_found_since`: その連続が始まった時刻。⚠ **終端にするかは「回数」ではなく
    #   「いつから」で決める** —— 掃除の間隔が変わっても判断が動かないため
    #
    # ⚠ `NOT NULL DEFAULT 0` なので既存の行は 0 で埋まる（組み替えは要らない）。
    def add_not_found_columns!(columns)
      unless columns.include?('not_found_streak')
        @db.execute(
          'ALTER TABLE entitlements ADD COLUMN not_found_streak INTEGER NOT NULL DEFAULT 0',
        )
      end
      return if columns.include?('not_found_since')

      @db.execute('ALTER TABLE entitlements ADD COLUMN not_found_since TEXT')
    end

    # ⚠⚠ **ストアの署名時刻が、いま入っているものより古ければ書かない**（Codex P2・
    # PR #75）。同じ購入を 2 本同時に確かめると、先に読んだ古い結果（active）が後から
    # 書かれて、新しい結果（expired）を上書きしうる。鍵では防げない ——
    # 付け替え前の行は購入ごとに別の行 ID を持つので、同じ購入でも別の鍵になる。
    # ⚠ 付け替え（`purchase_id`）は署名時刻に関係なく行う（行を正しい購入に寄せるだけで、
    # 状態は変えない）。
    def update_entitlement_verification!(entitlement_id, verification)
      v = verification
      @db.execute(<<~SQL, [v.purchase_id, entitlement_id])
        UPDATE entitlements SET purchase_id = ? WHERE id = ?
      SQL
      values = [v.product_id, v.status, v.expires_at, v.environment, v.signed_at]
      # ⚠ ストアが答えたので「知らない」の連続は切れる (#63)。⚠⚠ **書けたときだけ
      # 戻す** —— 古い結果が順序で弾かれた回に数えを消すと、終端までの日数が延びる。
      @db.execute(<<~SQL, values + [entitlement_id, v.signed_at, v.signed_at])
        UPDATE entitlements SET
          product_id = COALESCE(?, product_id),
          status = ?,
          expires_at = ?,
          environment = ?,
          signed_at = ?,
          not_found_streak = 0,
          not_found_since = NULL,
          updated_at = datetime('now')
        WHERE id = ? AND (signed_at IS NULL OR ? IS NULL OR signed_at <= ?)
      SQL
    end

    def merge_entitlement_tokens!(from_id, to_id)
      @db.execute(<<~SQL, [to_id, from_id])
        UPDATE OR IGNORE entitlement_tokens SET entitlement_id = ?, updated_at = datetime('now')
        WHERE entitlement_id = ?
      SQL
      @db.execute('DELETE FROM entitlement_tokens WHERE entitlement_id = ?', [from_id])
    end

    def create_entitlements_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS entitlements (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          store TEXT NOT NULL,
          purchase_id TEXT NOT NULL,
          product_id TEXT,
          status TEXT NOT NULL,
          expires_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(store, purchase_id)
        )
      SQL
    end

    def create_entitlement_tokens_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS entitlement_tokens (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          token TEXT NOT NULL,
          entitlement_id INTEGER NOT NULL,
          device_id TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(token),
          UNIQUE(entitlement_id, device_id),
          FOREIGN KEY (entitlement_id) REFERENCES entitlements(id) ON DELETE CASCADE
        )
      SQL
      # `subscriptions.device_id` から引く経路（#57 の 2-4）のための索引。
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_entitlement_tokens_device
        ON entitlement_tokens(device_id)
      SQL
    end

    # 購入の upsert。⚠ **既存行の `status` / `expires_at` は触らない。**
    # フェーズ 3 の検証結果を、クライアントからの再発行要求で `unverified` へ
    # 巻き戻さないため（アプリを再起動しただけで有効な購入が無効に見える）。
    def upsert_entitlement(store, purchase_id, product_id)
      @db.execute(<<~SQL, [store, purchase_id, product_id, ENTITLEMENT_STATUS_UNVERIFIED])
        INSERT INTO entitlements
          (store, purchase_id, product_id, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(store, purchase_id) DO UPDATE SET
          product_id = COALESCE(excluded.product_id, product_id),
          updated_at = datetime('now')
      SQL
      return @db.execute(
        'SELECT * FROM entitlements WHERE store = ? AND purchase_id = ?',
        [store, purchase_id],
      ).first
    end

    # 端末ごとの token の upsert。⚠ **既存行の `token` は差し替えない**
    # （[issue_entitlement_token] の doc）。
    def upsert_entitlement_token(entitlement_id, device_id)
      @db.execute(<<~SQL, [SecureRandom.urlsafe_base64(32), entitlement_id, device_id])
        INSERT INTO entitlement_tokens
          (token, entitlement_id, device_id, created_at, updated_at)
        VALUES (?, ?, ?, datetime('now'), datetime('now'))
        ON CONFLICT(entitlement_id, device_id) DO UPDATE SET
          updated_at = datetime('now')
      SQL
    end

    def find_entitlement_token_by_device(entitlement_id, device_id)
      return @db.execute(<<~SQL, [entitlement_id, device_id]).first
        SELECT t.id, t.token, t.entitlement_id, t.device_id,
               t.created_at, t.updated_at,
               e.store, e.purchase_id, e.product_id, e.status, e.expires_at, e.environment
        FROM entitlement_tokens t
        JOIN entitlements e ON t.entitlement_id = e.id
        WHERE t.entitlement_id = ? AND t.device_id = ?
      SQL
    end

    # サポーター状態 (capsicum#596 / #18)。将来の有償リレー利用権
    # (capsicum#597) はこの account-keyed entitlement 行を課金判定に
    # 格上げして再利用する想定。
    def create_supporters_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS supporters (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          account TEXT NOT NULL,
          server TEXT NOT NULL,
          first_tipped_at TEXT NOT NULL,
          tip_count INTEGER NOT NULL DEFAULT 0,
          last_sku TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(account, server)
        )
      SQL
    end

    def create_announcement_tables!
      create_announcement_subscriptions_table!
      create_seen_announcements_table!
    end

    # announcement_subscriptions の列定義。新規作成と FK 修復時の作り直しの両方が
    # 同じ定義を使う必要がある（片方だけ直すと、修復が古いスキーマのテーブルを
    # 生成してしまう）ため、1 箇所に集約する。
    def announcement_subscriptions_columns
      return <<~SQL
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        push_token TEXT NOT NULL,
        server TEXT NOT NULL,
        account TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(push_token, server, account),
        FOREIGN KEY (push_token) REFERENCES subscriptions(push_token) ON DELETE CASCADE
      SQL
    end

    def create_announcement_subscriptions_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS announcement_subscriptions (
          #{announcement_subscriptions_columns}
        )
      SQL
      # capsicum#468 リグレッションの自己修復。legacy_alter_table 未指定の
      # subscriptions 組み替えを経た環境では FK が subscriptions_old を指したまま
      # 壊れているので、正しい FK で作り直す（冪等。壊れていなければ何もしない）。
      repair_announcement_subscriptions_fk!
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_announcement_subscriptions_server
        ON announcement_subscriptions(server)
      SQL
      @db.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_announcement_subscriptions_push_token
        ON announcement_subscriptions(push_token)
      SQL
    end

    # capsicum#468 リグレッションの自己修復。announcement_subscriptions の FK が
    # 存在しない subscriptions_old を参照している場合、正しい FK
    # (subscriptions(push_token)) で作り直す。冪等で、壊れていなければ何もしない。
    # 当テーブルを rename する際も legacy_alter_table=ON で FK の二次書き換えを
    # 防ぐ（rebuild_subscriptions_table! と同じ理由）。
    def repair_announcement_subscriptions_fk!
      schema = @db.execute(<<~SQL).first
        SELECT sql FROM sqlite_master
        WHERE type = 'table' AND name = 'announcement_subscriptions'
      SQL
      return unless schema && schema['sql'].include?('subscriptions_old')

      @db.execute('PRAGMA foreign_keys=OFF')
      @db.execute('PRAGMA legacy_alter_table=ON')
      begin
        @db.transaction {rebuild_announcement_subscriptions_with_valid_fk!}
      ensure
        @db.execute('PRAGMA legacy_alter_table=OFF')
        @db.execute('PRAGMA foreign_keys=ON')
      end
    end

    # repair_announcement_subscriptions_fk! の組み替え本体。PRAGMA と transaction
    # は呼び出し側が張っているので、単体で呼んではいけない。
    def rebuild_announcement_subscriptions_with_valid_fk!
      @db.execute(
        'ALTER TABLE announcement_subscriptions RENAME TO announcement_subscriptions_broken',
      )
      @db.execute(<<~SQL)
        CREATE TABLE announcement_subscriptions (
          #{announcement_subscriptions_columns}
        )
      SQL
      @db.execute(<<~SQL)
        INSERT INTO announcement_subscriptions
          (id, push_token, server, account, created_at, updated_at)
        SELECT id, push_token, server, account, created_at, updated_at
        FROM announcement_subscriptions_broken
      SQL
      @db.execute('DROP TABLE announcement_subscriptions_broken')
    end

    def create_seen_announcements_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS seen_announcements (
          server TEXT NOT NULL,
          announcement_id TEXT NOT NULL,
          seen_at TEXT NOT NULL,
          PRIMARY KEY (server, announcement_id)
        )
      SQL
    end

    # device_id は nullable。device-id を送らない旧クライアントが従来どおり
    # (token, account, server) をキーに動き続けられるようにするため (#15)。
    # 実質的な UNIQUE(account, server, device_id) は migrate! の部分インデックス
    # 側で張る（SQLite はテーブル制約に WHERE を書けないため）。
    def create_subscriptions_table!
      @db.execute(<<~SQL)
        CREATE TABLE subscriptions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          token TEXT NOT NULL,
          push_token TEXT NOT NULL UNIQUE,
          device_type TEXT NOT NULL CHECK(device_type IN ('ios', 'android', 'macos', 'windows')),
          account TEXT NOT NULL,
          server TEXT NOT NULL,
          device_id TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(token, account, server)
        )
      SQL
    end

    def migrate_to_subscription_scoped!
      rebuild_subscriptions_table! do
        # 既存行は (device, account, server) のユニーク組（現スキーマ上
        # token UNIQUE なので 1:1 でコピー可能）。push_token は NULL 不許容に
        # 変わるため、万一 NULL のものがあれば埋める（運用上は 0 件想定）。
        @db.execute(<<~SQL)
          INSERT INTO subscriptions
            (id, token, push_token, device_type, account, server, created_at, updated_at)
          SELECT id, token,
                 COALESCE(push_token, lower(hex(randomblob(32)))),
                 device_type, account, server, created_at, updated_at
          FROM subscriptions_old
        SQL
      end
    end

    # device_type CHECK 拡張 (#468 macos / #474 windows) のための組み替え。最新
    # スキーマで作り直し、旧テーブルの全行をそのままコピーする。
    def rebuild_with_all_rows!
      rebuild_subscriptions_table! do
        old_columns = table_columns('subscriptions_old')
        list = COPYABLE_SUBSCRIPTION_COLUMNS.select {|c| old_columns.include?(c)}.join(', ')
        @db.execute("INSERT INTO subscriptions (#{list}) SELECT #{list} FROM subscriptions_old")
      end
    end

    def table_columns(table)
      return @db.execute("PRAGMA table_info(#{table})").map {|c| c['name']}
    end

    # subscriptions テーブルの CHECK / UNIQUE 等 ALTER 不能な変更のための
    # 組み替え共通処理。rename → 新スキーマ作成 → block でコピー → old drop。
    #
    # 子テーブル (announcement_subscriptions) が subscriptions(push_token) を FK
    # 参照しているため、素朴に rename すると SQLite が子テーブルの FK 参照名を
    # subscriptions_old へ自動書き換えし (legacy_alter_table OFF の既定動作)、
    # subscriptions_old を drop した後に FK がダングリングして以後の
    # announcement_subscriptions への INSERT が "no such table: subscriptions_old"
    # で 500 になる (capsicum#468 で実際に発生・リグレッション)。
    # legacy_alter_table=ON で rename を子テーブルに伝播させないことで防ぐ
    # (SQLite 公式の table-rebuild 手順)。foreign_keys は transaction 内では
    # 切り替えられないため transaction の外で OFF/ON する。
    def rebuild_subscriptions_table!
      @db.execute('PRAGMA foreign_keys=OFF')
      @db.execute('PRAGMA legacy_alter_table=ON')
      begin
        @db.transaction do
          @db.execute('ALTER TABLE subscriptions RENAME TO subscriptions_old')
          create_subscriptions_table!
          yield
          @db.execute('DROP TABLE subscriptions_old')
        end
      ensure
        @db.execute('PRAGMA legacy_alter_table=OFF')
        @db.execute('PRAGMA foreign_keys=ON')
      end
    end
  end
end
