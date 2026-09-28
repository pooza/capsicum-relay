require 'json'
require 'net/http'
require 'uri'
require_relative 'preset_servers'
require_relative 'vapid_assertion'
require_relative 'vapid_key_ledger'

module Relay
  # プリセットサーバーの VAPID 公開鍵を引いて覚えておく (#69)。
  #
  # ⚠⚠ **引くのは許可した一覧のホストだけ。**`subscription['server']` は
  # **クライアントの申告**なので、それをそのまま取りに行くと **relay が任意の
  # ホストへ HTTP を投げる道具になる**（SSRF）。⚠ **申告は「一覧のどれを名乗って
  # いるか」を選ぶためにしか使わない。**
  #
  # ⚠ **鍵は自動で追随させる。**9 ホストぶんを設定ファイルへ手で貼ると、
  # [Relay::PresetServers] の一覧と同じ「2 か所に同じものがある」形が増える。
  # 鍵はサーバーの公開 API から取れる（2026-09-28 に 9 ホストで実測。8 つで
  # 引けた —— `st2.misskey.delmulin.com` だけ `swPublickey` が null で、
  # **ステージングの Misskey は VAPID 未設定＝そもそも push を送れない**）:
  #
  # | | エンドポイント | 場所 |
  # | --- | --- | --- |
  # | Mastodon | `GET /api/v2/instance` | `configuration.vapid.public_key` |
  # | Misskey | `POST /api/meta` | `swPublickey` |
  #
  # ⚠ **どちらのソフトかは持っていない**ので、Mastodon → Misskey の順に試す。
  #
  # ⚠⚠ **引けなかったことと「鍵が違う」ことを混ぜない。**引けないのは**こちらの
  # 障害**で、そのときゲートは fail-open で通す（[Relay::EntitlementGate]）。
  # ここは **nil を返すだけ**で、倒し方は呼び出し側が決める。
  #
  # ⚠ **記録と枠は [Relay::VapidKeyLedger] が持つ。**ここは「どう引くか」だけ。
  class VapidKeyDirectory
    # ⚠ **短くする。**push の受け口の中で引くので、ここで待つとキューに積むのが遅れる。
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3

    # 起動時の先読みを待つ上限（秒・#78）。
    #
    # ⚠ **9 ホスト直列の実測は 488ms**（2026-09-28）なので、**通常は待ち切れる。**
    # ⚠⚠ **上限が要るのは、ホストが落ちている場合。**1 台で最大 12 秒（Mastodon の
    # 形 6 秒 + Misskey の形 6 秒）かかり、⚠ **待っている間 puma は listen して
    # いない ＝ nginx が 502**。🔴 **Misskey は 502 でも通知を捨てる**ので、
    # 待ち過ぎは `busy` より悪い。
    WARM_BUDGET = 5

    # 先読みを繰り返す間隔（秒・PR #79 の Codex P1）。
    #
    # ⚠⚠ **1 回だけ温めても足りない。**起動時に全ホストを**ほぼ同時**に覚えるので、
    # **TTL（6 時間）後に 9 個が一斉に期限切れになる** —— そこで冷えたバーストが
    # そのまま再現する（1 本目が枠を握り、残りが `busy`）。長く動いているプロセス
    # ほど確実に踏む。
    #
    # ⚠ **TTL より十分短く**する。⚠ **引き直しは [Relay::VapidKeyLedger::
    # MIN_REFRESH_INTERVAL]（60 秒）で絞られている**ので、これより短くしても
    # 実際には引かない。
    WARM_REFRESH_INTERVAL = 60 * 60

    # [hosts] は引いてよいホスト（プリセット + `extra_preset_hosts`）。
    # [fetch] はテスト用の差し替え口で、`->(uri, payload) { body or nil }`。
    # payload が nil なら GET、文字列なら JSON の POST。
    def initialize(hosts:, ttl: Relay::VapidKeyLedger::DEFAULT_TTL,
      negative_ttl: Relay::VapidKeyLedger::DEFAULT_NEGATIVE_TTL,
      fetch: nil, clock: -> {Time.now.to_f})
      @hosts = Array(hosts).map {|host| Relay::PresetServers.normalize(host)}.reject(&:empty?).to_set
      @fetch = fetch || method(:http_fetch)
      @ledger = Relay::VapidKeyLedger.new(ttl: ttl, negative_ttl: negative_ttl, clock: clock)
    end

    # 引けたら base64url（パディング無し）に揃えた公開鍵。
    #
    # ⚠⚠ **戻り値は 3 通り (#69・Codex P1 6 巡目)。**
    #
    # | 戻り値 | 意味 | 呼び出し側 |
    # | --- | --- | --- |
    # | 鍵（String） | 引けた | 照合する |
    # | `nil` | **外部の障害**で引けなかった | ⚠ fail-open |
    # | [Relay::VapidKeyLedger::BUSY] | **競合**（枠が埋まっている） | ⚠⚠ **fail-open にしない**（再試行させる） |
    #
    # ⚠⚠ **競合を `nil` に畳まない。**畳むと、**同時リクエストを撃つだけで確定的に
    # ゲートを抜けられる** —— 1 本目が枠を取り、2 本目が「外部障害」として通る。
    #
    # ⚠ **枠は 2 段階。プロセス全体 → ホストごと、の順に押さえる。**順を逆に
    # すると、**全体の枠が取れなかったときにホストの枠だけ焼く**ので、引いても
    # いないのに 60 秒間そのホストが引き直せなくなる。
    def public_key_for(server)
      host = allowed(server)
      return nil unless host
      return @ledger.read(host) if @ledger.fresh?(host)
      return Relay::VapidKeyLedger::BUSY unless @ledger.acquire_slot

      begin
        # ⚠ 枠は取れたのに予約が取れない ＝ 誰かが引いている最中 / 直前に試した。
        return @ledger.throttled_outcome(host) unless @ledger.reserve(host)

        key = discover(host)
        # ⚠ 引けなければ negative cache（従来どおり）。手元の鍵は既に期限切れ。
        return @ledger.store(host, key)
      ensure
        @ledger.release_slot
      end
    end

    # ⚠⚠ **鍵が合わなかったときに 1 度だけ引き直す (#69・PR #77 の Codex P1)。**
    #
    # **プリセットサーバーが VAPID を作り直すと、TTL のあいだ手元は古い鍵のまま**に
    # なる。そのあいだ本物の push が全部 `mismatch` になり、⚠⚠ **ゲートを閉じて
    # いると 410 を返して上流の購読が永久に消える。**取り返しがつかないので、
    # 詐称と決める前に必ず引き直す。
    #
    # 戻り値は [public_key_for] と同じ 3 通り。⚠ **古い鍵をそのまま返さない**
    # （呼び出し側が**引き直した結果**と読んで詐称判定に倒す）。
    def refresh_key_for(server)
      host = allowed(server)
      return nil unless host
      # ⚠ **間隔の判定は枠の前。**I/O をしないので、枠を待たせる必要が無い。
      return @ledger.throttled_outcome(host) if @ledger.throttled?(host)
      return Relay::VapidKeyLedger::BUSY unless @ledger.acquire_slot

      begin
        return @ledger.throttled_outcome(host) unless @ledger.reserve(host)

        key = discover(host)
        # ⚠ **引けなかったら手元の記録を壊さない。**`failed` を立てるだけ。
        return @ledger.mark_failed(host) if key.nil?

        return @ledger.store(host, key)
      ensure
        @ledger.release_slot
      end
    end

    # [Relay::VapidKeyLedger::BUSY] を返したときに、上流へ伝える待ち時間（秒）。
    #
    # ⚠ **一覧の外のホストはここへ来ない**（[BUSY] にならない）が、呼び出し側が
    # 分岐を持たなくて済むよう既定値を返す。
    def retry_after_for(server)
      host = allowed(server)
      return Relay::VapidKeyLedger::CONTENTION_RETRY_AFTER if host.nil?

      return @ledger.retry_after(host)
    end

    # 鍵の温まり具合（#78）。`{fresh:, total:}`。
    #
    # ⚠⚠ **先読みが効いたかを外から見るための口。**これが無いと、
    # **`warm!` が空振りしていても気付けない**（[warm!] は無言で、
    # `relay_vapid_verification_total` は push が来るまで 1 件も出ない）。
    #
    # ⚠ **数えるのは期限内の鍵だけ**（PR #79 の Codex P2）。期限切れを混ぜると
    # **TTL が切れても数字が動かず、「冷えている」が読めない。**
    #
    # ⚠⚠ **`fresh` が `total` を下回っている ＝ そのホスト宛の push は `busy`
    # （503）になり得る。**🔴 Misskey は 5xx を再送しないので通知が消える。
    def cached_counts
      return {fresh: @hosts.count {|host| !@ledger.read(host).nil?}, total: @hosts.size}
    end

    # ⚠⚠ **起動時にプリセットの鍵を引いておく (#78)。**
    #
    # これが無いと、**再起動直後に同時に来た push が全部 `busy`（503）になる** ——
    # 2026-09-28 の本番投入直後に **3 通中 2 通**で実測した。🔴 **Misskey は 5xx を
    # 再送しないので、その通知は黙って消える。**
    #
    # ⚠⚠ **温め終えてから受け付ける**（PR #79 の Codex P1）。背景に投げっぱなしに
    # すると、**温めている最中に来た push が `busy` になる** —— warm は唯一の枠を
    # 握るので、**まだ温まっていないホストには手元の鍵も無く、倒しようがない。**
    #
    # ⚠ **実測 488ms**（9 ホスト直列・2026-09-28）。**待っても実質ゼロコスト。**
    #
    # ⚠⚠ **ただし無制限に待たない。**ホストが落ちていると **1 台で最大 12 秒**
    # （Mastodon の形 6 秒 + Misskey の形 6 秒）かかり、9 台なら 100 秒を超える。
    # **待っている間 puma は listen していない ＝ nginx が 502 を返す**ので、
    # 🔴 **Misskey 宛はそこでも落ちる**（再送しないため）。**どちらも失うなら
    # 短いほうを選ぶ。**
    #
    # → **[budget] 秒だけ待ち、終わらなければ残りは背景で続ける。**
    #
    # ⚠ **直列に引く** —— 枠は [Relay::VapidKeyLedger::MAX_CONCURRENT_DISCOVERY] で
    # 1 本に絞ってあるので、並列にしても意味が無いうえ受け口と枠を奪い合う。
    # ⚠ **失敗は無視してよい**（negative cache に入るだけ）。
    def warm!(budget: WARM_BUDGET, interval: WARM_REFRESH_INTERVAL)
      warmed = Queue.new
      thread = Thread.new do
        each_host {|host| public_key_for(host)}
        warmed << true
        # ⚠⚠ **TTL の前に引き直し続ける。**1 回だけだと 6 時間後に全ホストが
        # 一斉に期限切れになり、冷えたバーストがそのまま戻る（[WARM_REFRESH_INTERVAL]）。
        while interval.to_f.positive?
          sleep(interval)
          each_host {|host| refresh_key_for(host)}
        end
      end
      # ⚠⚠ **`join` で待たない。**繰り返すぶんスレッドは終わらないので、
      # `join(budget)` だと**毎回 budget を丸ごと待つ**（実際に踏んだ）。
      # **待つのは「1 巡目が終わったか」だけ。**
      warmed.pop(timeout: budget)
      return thread
    end

    # テストと、設定を読み直したときのための口。
    def reset!
      @ledger.clear
    end

    private

    # ⚠ 一覧に無いホストは**取りに行かない**（SSRF を作らないための入口）。
    def allowed(server)
      host = Relay::PresetServers.normalize(server)
      return @hosts.include?(host) ? host : nil
    end

    # ⚠⚠ **1 ホストずつ rescue する（PR #79 の Codex P2）。**ループ全体を囲うと、
    # **1 台の妙な応答で以降のホストが全部冷えたまま**になり、その最初の同時 push が
    # また `busy` になる。
    def each_host
      @hosts.each do |host|
        yield(host)
      rescue StandardError
        next
      end
    end

    # ⚠ **Mastodon → Misskey の順に試す。**どちらでもなければ nil。
    def discover(host)
      return mastodon_key(host) || misskey_key(host)
    end

    def mastodon_key(host)
      body = call("https://#{host}/api/v2/instance", nil)
      return normalize(dig_in(parse(body), 'configuration', 'vapid', 'public_key'))
    end

    def misskey_key(host)
      body = call("https://#{host}/api/meta", '{"detail":false}')
      return normalize(dig_in(parse(body), 'swPublickey'))
    end

    # ⚠⚠ **`Hash#dig` を直に使わない（PR #79 の Codex P2）。**サーバーが
    # `{"configuration":"unexpected"}` のような**形は正しいが中身が違う** JSON を
    # 返すと、`String` に `dig` は無いので **TypeError が飛ぶ。**
    #
    # 🔴 **これは先読みが止まるだけの話ではない。**[public_key_for] は route から
    # 呼ばれていて**例外を捕まえていない**ので、⚠⚠ **`/push` が 500 になる**
    # （2026-09-28 に実測して確認した）。**途中が Hash でなければ nil にする。**
    def dig_in(json, *path)
      return path.reduce(json) do |node, key|
        break nil unless node.is_a?(Hash)

        node[key]
      end
    end

    # ⚠ **何が起きても nil。**外向きの HTTP は落ちる前提で、push の受け口を
    # 巻き込まない。「引けなかった」は呼び出し側が metrics に出す。
    def call(url, payload)
      return @fetch.call(URI.parse(url), payload)
    rescue StandardError
      return nil
    end

    def parse(body)
      return nil if body.nil?

      json = JSON.parse(body)
      return json.is_a?(Hash) ? json : nil
    rescue JSON::ParserError
      return nil
    end

    # ⚠ ヘッダ側と同じ形へ揃えてから覚える（[Relay::VapidAssertion.normalize_key]）。
    #
    # ⚠⚠ **揃えるだけでなく、P-256 の公開鍵として読めるかまで見る**（Codex 8 巡目）。
    # 空でない壊れた値をそのまま覚えると、**本物の署名が永久に一致せず 410 で
    # 購読が消える。**読めない値は nil ＝「引けなかった」にして fail-open させる
    # （Mastodon の形で壊れていれば、この後 Misskey の形も試される）。
    def normalize(value)
      key = value.to_s.strip
      return nil if key.empty?

      normalized = Relay::VapidAssertion.normalize_key(key)
      return Relay::VapidAssertion.public_key?(normalized) ? normalized : nil
    end

    # ⚠ **リダイレクトを追わない。**追うと一覧の外のホストへ出て行けてしまう。
    def http_fetch(uri, payload)
      request = build_request(uri, payload)
      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
      ) {|http| http.request(request)}
      return response.is_a?(Net::HTTPSuccess) ? response.body : nil
    end

    def build_request(uri, payload)
      return Net::HTTP::Get.new(uri) if payload.nil?

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request.body = payload
      return request
    end
  end
end
