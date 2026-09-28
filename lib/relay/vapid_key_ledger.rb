require 'monitor'

module Relay
  # [Relay::VapidKeyDirectory] が「何を覚えていて、いつ引き直してよいか」を
  # 持つところ (#69)。⚠ **外向きの HTTP は持たない。**引くのは Directory の仕事で、
  # ここは**記録と枠**だけ —— 2 つを 1 クラスに混ぜると、どちらの都合で
  # どの分岐があるのかが読めなくなる。
  #
  # 記録は `[鍵, 期限, 引き直しを試みた時刻, その試みが失敗したか]`。
  # ⚠ **4 つ目は「引き直し」だけのための印。**[read] の経路は見ない
  # （手元の鍵は期限まで有効で、引き直しの成否とは別の話）。
  class VapidKeyLedger
    # 引き直す間隔。⚠ **鍵の更新は滅多に起きない**（サーバーの VAPID を作り直した
    # ときだけ）ので長くてよい。⚠ **短くすると push 1 通ごとの外向き HTTP が増える。**
    DEFAULT_TTL = 6 * 60 * 60
    # 引けなかったときに次に試すまで。⚠ **落ちているサーバーを叩き続けない。**
    DEFAULT_NEGATIVE_TTL = 10 * 60
    # [reserve] を続けて呼ばれたときに、実際に引き直す最短間隔。
    #
    # ⚠⚠ **これが無いと DoS の踏み台になる。**引き直しは「鍵が合わない push が
    # 来た」ときに走るので、**合わない鍵で叩き続けるだけでプリセットサーバーへ
    # 好きなだけ HTTP を出させられる。**
    MIN_REFRESH_INTERVAL = 60
    # プロセス全体で同時に走らせてよい discover の数 (#69・Codex P1 5 巡目)。
    #
    # ⚠⚠ **ホストごとの予約は同じホストしか直列化しない。**`config/puma.rb` は
    # **2 スレッド**なのに一覧には **9 ホスト**あるので、**別のホストを名乗る
    # 2 件が同時に来るだけで受け口が埋まる** —— それぞれが GET/POST の timeout を
    # 待つあいだ、relay は push を 1 通も受け付けられない。⚠ **クライアントは
    # 好きなホストを名乗れる**ので、攻撃者がこれを起こせる。
    MAX_CONCURRENT_DISCOVERY = 1

    # 枠の取り合いで待たせるときの `Retry-After`（秒）。引き終わるまでなので、
    # 最長でも discover の timeout 2 本ぶん。
    CONTENTION_RETRY_AFTER = 5

    KEY = 0
    EXPIRES_AT = 1
    ATTEMPTED_AT = 2
    # ⚠⚠ **3 状態。**`:in_flight`（誰かが引いている最中）と `:failed`（引いて
    # 失敗した）を**同じ値にしない (#69・Codex P1 6 巡目)。**畳むと、呼び出し側が
    # **競合を外部障害と読んで fail-open し、同時リクエストで確定的にゲートを
    # 抜けられる。**
    STATE = 3
    private_constant :KEY, :EXPIRES_AT, :ATTEMPTED_AT, :STATE

    IN_FLIGHT = :in_flight
    FAILED = :failed
    OK = :ok

    # 競合（枠が埋まっている / 誰かが引いている最中）。⚠ **外部障害と区別する。**
    BUSY = :busy

    def initialize(ttl: DEFAULT_TTL, negative_ttl: DEFAULT_NEGATIVE_TTL, clock: -> {Time.now.to_f})
      @ttl = ttl
      @negative_ttl = negative_ttl
      @clock = clock
      @entries = {}
      @discovering = 0
      @mon = Monitor.new
    end

    # 期限内の鍵。無ければ nil。⚠ **鍵が nil の negative cache も「期限内」**
    # なので、戻り値だけでは引きに行くべきか決められない（[fresh?] を見る）。
    def read(host)
      return @mon.synchronize do
        entry = @entries[host]
        next nil if entry.nil?
        next nil if entry[EXPIRES_AT] < @clock.call

        entry[KEY]
      end
    end

    # 期限内の記録があるか（鍵が nil でも true）。
    #
    # ⚠⚠ **引いている最中の「まだ鍵が無い」予約は fresh ではない。**
    # [reserve] は期限を先に置くので、そのままだと**冷えたキャッシュへの同時要求が
    # 「期限内の nil」を受け取り、競合を外部障害として fail-open する**（実測で
    # 踏んだ）。⚠ **鍵を持ったままの引き直し中は fresh のまま**（手元の鍵は
    # 期限まで有効で、返して問題ない）。
    def fresh?(host)
      return @mon.synchronize do
        entry = @entries[host]
        next false if entry.nil?
        next false if entry[KEY].nil? && entry[STATE] == IN_FLIGHT

        entry[EXPIRES_AT] >= @clock.call
      end
    end

    # 間隔の中か（[MIN_REFRESH_INTERVAL]）。⚠ I/O をしないので枠の前に見てよい。
    def throttled?(host)
      now = @clock.call
      return @mon.synchronize do
        entry = @entries[host]
        !entry.nil? && (now - entry[ATTEMPTED_AT]) < MIN_REFRESH_INTERVAL
      end
    end

    # 間隔のあいだに来た要求への答え。⚠ **手元の鍵は絶対に返さない。**
    #
    # | 直前の試み | 戻り値 | 呼び出し側 |
    # | --- | --- | --- |
    # | **失敗した** | `nil` | ⚠ 外部の障害 → fail-open |
    # | それ以外（引いている最中 / 成功した） | [BUSY] | ⚠⚠ 競合 → 再試行させる |
    #
    # ⚠⚠ **成功した直後でも [BUSY] を返す (#69・Codex P1 7 巡目)。**
    # 「引けた鍵」と「**いま引き直した**鍵」は違う —— **引いた 60 秒の間に
    # サーバーが VAPID を作り直すと、手元の鍵は既に古い。**それを「引き直した
    # 結果」として返すと、呼び出し側が**本物の新しい鍵を詐称と判定し、410 で
    # 上流の購読を永久に消す。**
    #
    # ⚠ **3 巡目で `failed` について直したのと同じ穴が、`ok` に残っていた。**
    def throttled_outcome(host)
      return @mon.synchronize do
        entry = @entries[host]
        next nil if entry.nil?
        next nil if entry[STATE] == FAILED

        BUSY
      end
    end

    # [BUSY] を返すときに上流へ伝える待ち時間（秒）。
    #
    # ⚠⚠ **一律に 1 秒と答えてはいけない（PR #77 の Codex 締めの P2）。**
    # [BUSY] には由来が 2 つあり、**明けるまでの長さが 1 桁違う**:
    #
    # | 由来 | 明けるまで |
    # | --- | --- |
    # | 枠の取り合い（[acquire_slot] / [IN_FLIGHT]） | 引き終わるまで＝[CONTENTION_RETRY_AFTER] |
    # | 引き直しの間隔（[MIN_REFRESH_INTERVAL]） | ⚠ **最大 60 秒** |
    #
    # ⚠ 後者に 1 秒と答えると、**上流は間隔が明けるまで 503 を受け続け、
    # 再試行の枠を使い切る** —— 通知が遅れる / 落ちる。
    #
    # ⚠ **短いほうへ丸めない**（残りが短ければそのぶんだけ待たせる）。
    def retry_after(host)
      now = @clock.call
      return @mon.synchronize do
        entry = @entries[host]
        next CONTENTION_RETRY_AFTER if entry.nil?

        remaining = MIN_REFRESH_INTERVAL - (now - entry[ATTEMPTED_AT])
        next CONTENTION_RETRY_AFTER if remaining <= CONTENTION_RETRY_AFTER

        remaining.ceil
      end
    end

    # ⚠⚠ **I/O の前に枠を押さえる。**チェックと更新を 1 つの critical section に
    # 入れないと、**間隔が明けた直後の同時要求が全部素通りする**（Codex P1 3 巡目）。
    #
    # ⚠ **[IN_FLIGHT] を立ててから出ていく。**引いている最中に来た要求には
    # [BUSY] を返したい（＝ **fail-open にしない**）ので、結末が出たら
    # [store] / [mark_failed] が倒す。
    def reserve(host)
      now = @clock.call
      return @mon.synchronize do
        entry = @entries[host]
        next false if entry && (now - entry[ATTEMPTED_AT]) < MIN_REFRESH_INTERVAL

        @entries[host] = if entry.nil?
          [nil, now + @negative_ttl, now, IN_FLIGHT]
        else
          [entry[KEY], entry[EXPIRES_AT], now, IN_FLIGHT]
        end
        true
      end
    end

    # 引けなかった。⚠ **鍵と期限は残す**（一時的な障害で記録を壊さない）。
    def mark_failed(host)
      @mon.synchronize do
        entry = @entries[host]
        next if entry.nil?

        @entries[host] = [entry[KEY], entry[EXPIRES_AT], entry[ATTEMPTED_AT], FAILED]
      end
      return nil
    end

    def store(host, key)
      ttl = key.nil? ? @negative_ttl : @ttl
      now = @clock.call
      @mon.synchronize {@entries[host] = [key, now + ttl, now, OK]}
      return key
    end

    # ⚠ **取れなければ呼び出し側は nil に倒す**（fail-open）。待たせない ——
    # 待たせたらスレッドを占有されるのと同じことになる。
    def acquire_slot
      return @mon.synchronize do
        next false if @discovering >= MAX_CONCURRENT_DISCOVERY

        @discovering += 1
        true
      end
    end

    def release_slot
      @mon.synchronize {@discovering -= 1}
    end

    def clear
      @mon.synchronize {@entries.clear}
    end
  end
end
