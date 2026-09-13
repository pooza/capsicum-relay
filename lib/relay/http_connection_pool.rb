require 'monitor'
require 'net/http'

module Relay
  # ホスト別の keep-alive 接続プール (#54)。
  #
  # ## なぜ要るか
  #
  # WNS への push が **1 通 2,056ms** かかっており（APNs 126ms / FCM 175ms）、
  # relay の処理時間の 88% を Windows が占めていた。原因は `WnsClient#post_raw` が
  # 1 通ごとに `Net::HTTP.start` を呼んでいたこと ＝ 毎回 TCP 3-way + TLS。
  # **WNS チャネルはダブリン (db5p) にあり、接続確立だけで 690ms**（日本からの
  # RTT 230ms × ハンドシェイク）。APNs が速いのは `Apnotic::Connection` を
  # 持ち続けているからで、FCM が毎回張り直しても平気なのは Google のエッジが
  # 国内にあるからだった。⚠ **「毎回張り直す」実装が痛いのは宛先が遠い WNS だけ。**
  #
  # ## 設計
  #
  # - **ホスト別に分ける。** Channel URI の region は Microsoft の割り当てで
  #   db5p / sg2p 等に分かれる。1 本を共有すると別ホストへ使い回してしまう
  # - **貸出中の接続はプールに残さない** (checkout / checkin)。`Net::HTTP` は
  #   1 オブジェクトへの同時リクエストが安全でないため。puma は `threads 2` +
  #   お知らせ worker のスレッドがあり、同時送信は起こりうる
  # - **アイドルの破棄は checkout 時に見る。**バックグラウンドの reaper は置かない
  #   （1 ホスト最大 [MAX_IDLE_PER_HOST] 本しか持たないので、放置しても
  #   サーバー側が閉じる。⚠ 常駐スレッドを増やすほうが壊れ方が難しい）
  #
  # ## ⚠⚠ `keep_alive_timeout` を必ず上げる
  #
  # `Net::HTTP#keep_alive_timeout` の既定は **2 秒**で、**前回のリクエストから
  # これを超えて空いた接続は `Net::HTTP` が黙って張り直す**（`begin_transport`）。
  # 上げずにプールすると、**「再利用した」と記録しながら実際には毎回ハンドシェイク
  # している**状態になり、計測が嘘をつく。プールのアイドル上限と揃えてある。
  class HttpConnectionPool
    # アイドル接続を再利用してよい秒数。WNS は IIS 前段で、既定の keep-alive は
    # 120 秒。⚠ **サーバー側の上限より短く**しないと、こちらが生きていると思って
    # いる接続へ書き込んで stale 例外を踏む頻度が上がる。
    IDLE_TIMEOUT = 55
    # 1 ホストあたり保持するアイドル接続の本数。puma の threads と同数で足りる
    # （同時送信の最大値）。これを超えたぶんは checkin で閉じる。
    MAX_IDLE_PER_HOST = 2
    # 接続確立とレスポンス待ちの上限 (秒)。⚠ **既定 (60s) のままにしない。**
    # puma は 2 スレッドなので、1 本が長く詰まると relay 全体の受け口が細る。
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    # プールに寝ている 1 本。`idle_since` は checkin した時刻。
    Entry = Struct.new(:http, :idle_since)

    # [factory] はテスト用の差し替え口。`call(host, port)` で開始済みの接続
    # 相当を返すものを渡す（既定は実物の `Net::HTTP`）。
    def initialize(
      idle_timeout: IDLE_TIMEOUT,
      max_idle_per_host: MAX_IDLE_PER_HOST,
      logger: nil,
      factory: nil
    )
      @idle_timeout = idle_timeout
      @max_idle_per_host = max_idle_per_host
      @logger = logger
      @factory = factory
      @idle = {}
      @mon = Monitor.new
    end

    # 接続を借りる。返り値は `[接続, 再利用したか]`。
    #
    # ⚠ **再利用したかを呼び出し側へ返すのは飾りではない。**(1) stale な接続で
    # 落ちたときに再送してよいのは再利用だった場合だけ（新規接続での失敗を
    # 再送すると二重送信を作る）、(2) ヒット率を実測する材料になる。
    def checkout(host, port)
      reusable = @mon.synchronize {take_reusable(key_for(host, port))}
      return [reusable, true] if reusable

      return [build(host, port), false]
    end

    # 使い終わった接続を返す。閉じられていた / 上限を超えたぶんは閉じる。
    def checkin(host, port, http)
      return close_quietly(http) unless http

      key = key_for(host, port)
      kept = @mon.synchronize do
        next false unless keepable?(key, http)

        (@idle[key] ||= []).push(Entry.new(http, Time.now))
        next true
      end
      return true if kept

      close_quietly(http)
      return false
    end

    # 壊れた接続を捨てる。プールには戻さない。
    def discard(http)
      return close_quietly(http)
    end

    # 保持中のアイドル接続を全部閉じる（プロセス終了時・テスト）。
    def close_all
      entries = @mon.synchronize do
        all = @idle.values.flatten
        @idle.clear
        all
      end
      entries.each {|entry| close_quietly(entry.http)}
      return entries.size
    end

    # 保持中のアイドル本数（テスト・観測用）。
    def idle_count(host = nil, port = nil)
      return @mon.synchronize do
        next @idle.values.sum(&:size) if host.nil?

        (@idle[key_for(host, port)] || []).size
      end
    end

    private

    def key_for(host, port)
      return [host.to_s.downcase, port]
    end

    # 使える 1 本が出るまで後ろから取る。使えないものはその場で閉じる。
    # ⚠ 再帰は最大 [MAX_IDLE_PER_HOST] 段。@mon を握ったまま呼ばれる。
    def take_reusable(key)
      entries = @idle[key]
      return nil if entries.nil? || entries.empty?

      entry = entries.pop
      return entry.http if usable?(entry)

      close_quietly(entry.http)
      return take_reusable(key)
    end

    # ⚠⚠ **これで「生きている」ことは確かめられない。**`started?` は自分が
    # start したかどうかで、**相手が閉じたことは分からない**。アイドル時間で
    # 見切るしかなく、それでも取りこぼすので、**呼び出し側に stale の再送が要る**
    # （[Relay::WnsClient#post_raw]）。
    def usable?(entry)
      return false unless entry.http.started?

      return (Time.now - entry.idle_since) < @idle_timeout
    end

    # プールへ戻してよいか。閉じられたもの・上限を超えたぶんは持たない。
    def keepable?(key, http)
      return false unless http.started?

      return (@idle[key] || []).size < @max_idle_per_host
    end

    def build(host, port)
      return @factory.call(host, port) if @factory

      http = configure(Net::HTTP.new(host, port))
      http.start
      return http
    end

    # ⚠ **start と分けてある。**`keep_alive_timeout` を上げ忘れると「再利用した」と
    # 記録しながら実際には毎回ハンドシェイクする（クラスコメント）ので、**外へ出ない
    # 形でここだけを検査できるようにしてある**。
    def configure(http)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.keep_alive_timeout = @idle_timeout
      return http
    end

    # close は相手が既に切っている等で例外になりうる。捨てるのが目的なので握る。
    def close_quietly(http)
      http&.finish if http&.started?
      return true
    rescue StandardError => e
      @logger&.warn("HTTP connection close failed (ignored): #{e.class}: #{e.message}")
      return false
    end
  end
end
