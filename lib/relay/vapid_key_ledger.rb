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

    KEY = 0
    EXPIRES_AT = 1
    ATTEMPTED_AT = 2
    FAILED = 3
    private_constant :KEY, :EXPIRES_AT, :ATTEMPTED_AT, :FAILED

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
    def fresh?(host)
      return @mon.synchronize do
        entry = @entries[host]
        !entry.nil? && entry[EXPIRES_AT] >= @clock.call
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

    # 間隔のあいだに来た要求への答え。
    #
    # ⚠⚠ **直前の試みが失敗（または進行中）なら nil。**手元の古い鍵を返すと、
    # 呼び出し側が**引き直した結果**と読んで詐称判定に倒し、410 で購読が消える。
    def throttled_result(host)
      return @mon.synchronize do
        entry = @entries[host]
        next nil if entry.nil?
        next nil if entry[FAILED]

        entry[KEY]
      end
    end

    # ⚠⚠ **I/O の前に枠を押さえる。**チェックと更新を 1 つの critical section に
    # 入れないと、**間隔が明けた直後の同時要求が全部素通りする**（Codex P1 3 巡目）。
    #
    # ⚠ **悲観的に「失敗」を立ててから出ていく。**引いている最中に来た要求には
    # nil を返したい（＝ fail-open）ので、成功したときに [store] が倒す。
    def reserve(host)
      now = @clock.call
      return @mon.synchronize do
        entry = @entries[host]
        next false if entry && (now - entry[ATTEMPTED_AT]) < MIN_REFRESH_INTERVAL

        @entries[host] = if entry.nil?
          [nil, now + @negative_ttl, now, true]
        else
          [entry[KEY], entry[EXPIRES_AT], now, true]
        end
        true
      end
    end

    def store(host, key)
      ttl = key.nil? ? @negative_ttl : @ttl
      now = @clock.call
      @mon.synchronize {@entries[host] = [key, now + ttl, now, false]}
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
