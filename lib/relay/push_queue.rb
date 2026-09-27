require 'monitor'

require_relative 'push_delivery_reporter'

module Relay
  # 上流から受けた push を**非同期に**配送するキュー (#55)。
  #
  # ## なぜ要るか
  #
  # 配送が同期だったので、**遅い 1 通が puma のスレッドを占有していた**。
  # puma は `workers 0` / `threads 2` ＝ **同時に 2 通**で、Windows は 1 通あたり
  # 平均 **2,056ms**（#54 の実測）。⚠ **Windows の 2 通が並ぶと、その約 2 秒は
  # 他の push を受け付けられない。**7 日の実測で **Windows が総処理時間の 88%**
  # を占めており、**利用者数ではなく Windows が relay の容量を決めていた。**
  #
  # ⚠ **WNS の遅さそのものは消えない**が、**受信経路を塞がなくなる**。
  #
  # ## ⚠⚠ 上流へ結末を返せなくなる、への答え
  #
  # 受け取った時点で `202` を返すので、配送の結末（success / gone / failed）を
  # 上流へ伝える手段が無くなる。⚠ とくに **`gone`（device token が無効）で
  # `410` を返して購読を掃除させる経路**が効かなくなる。
  #
  # → [Relay::PushDeliveryReporter] が `gone` で relay 側の行を落とし、
  # **次の push が `410 Unknown push token` を返す**ことで掃除される。
  # ⚠ **1 通だけ「受け取ったのに届かない」通知が出る**のは承知の上のコスト。
  #
  # ## ⚠ 再試行はしない（実測に基づく判断）
  #
  # 本番 30 日の `failed` 36 件の内訳は **android × FCM 400 が 25 件**（恒久的な
  # 失敗で、再送しても通らない）/ windows の unknown 10 件 / no_response 1 件。
  # ⚠⚠ **再試行で救えるものがほぼ無い。**しかも同期のときは 502 を返して
  # **Mastodon に 5 回 retry させていた**ので、**FCM 400 を 5 回投げ直していた**
  # ことになる。やめるのは改善。
  #
  # ⚠ **APNs / FCM の 5xx が出るようになったら再試行を入れ直す**（30 日で 0 件）。
  #
  # ## ⚠⚠ 満杯のときは 5xx で断る（黙って捨てない）
  #
  # 無制限にすると WNS の障害でメモリが伸び続ける。満杯なら上流へ **503** を
  # 返して retry させる。⚠ **4xx にしてはいけない**（Mastodon が購読を消す・#66）。
  class PushQueue
    # 積める通数。⚠ **深くしない。**ピークは 21 通/分で、ワーカーが追いついて
    # いれば 0 のままになる。深いキューは「詰まっているのに気付かない」時間を
    # 延ばすだけで、⚠ **再起動で失う通数も増える。**
    DEFAULT_CAPACITY = 200

    # 配送を並行して行うスレッド数。
    #
    # ⚠⚠ **[Relay::HttpConnectionPool::MAX_IDLE_PER_HOST] と揃える必要がある。**
    # あちらは「同時送信の最大値」として puma の threads と同数（2）で決め打たれて
    # おり、超えたぶんは checkin で閉じられる ＝ **#54 の接続再利用が効かなくなる。**
    # 増やすときは両方見ること。
    DEFAULT_WORKERS = 2

    # 停止時にキューを吐き切るのを待つ上限 (秒)。
    #
    # ⚠ **systemd の `TimeoutStopSec` より短く。**超えると SIGKILL されて、
    # 待った意味が無くなる（吐き切れず、かつ停止が遅いだけになる）。
    DRAIN_TIMEOUT = 10

    Job = Struct.new(:subscription, :payload, :request_id, :queued_at, keyword_init: true)

    # ⚠ route 側が `record_rejected` のために借りる（配送そのものはワーカーが持つ）。
    attr_reader :reporter

    def initialize(deliver:, reporter:, capacity: DEFAULT_CAPACITY, workers: DEFAULT_WORKERS)
      # [deliver] は `call(subscription, payload)` で push クライアントの戻り値を
      # 返すもの。⚠ **クライアントの選択はここに持たない**（route 側が
      # `push_client_for` で 503 を先に返すため・クラスの doc を参照）。
      @deliver = deliver
      @reporter = reporter
      @queue = SizedQueue.new(capacity)
      @workers = workers
      @threads = []
      # ⚠ **「キューが空」は「配送が終わった」ではない。**pop された 1 通はまだ
      # ワーカーの中にいる。停止時とテストで「本当に捌けたか」を言うために数える。
      @in_flight = 0
      @mon = Monitor.new
    end

    def start!
      @threads = Array.new(@workers) do |index|
        thread = Thread.new do
          Thread.current.name = "push_queue_#{index}"
          run_loop
        end
        thread.report_on_exception = true
        thread
      end
      return self
    end

    # 受け取れたら true。⚠ **満杯なら待たずに false**（待つと受信経路を塞ぐので、
    # 非同期にした意味が消える）。
    def enqueue(subscription:, payload:, request_id: nil)
      @queue.push(
        Job.new(
          subscription: subscription, payload: payload, request_id: request_id,
          queued_at: monotonic_now
        ),
        true, # non_block
      )
      return true
    rescue ThreadError
      return false
    end

    def depth
      return @queue.size
    end

    def empty?
      return @queue.empty?
    end

    # 積まれておらず、配送中も無い。
    def idle?
      return @queue.empty? && @mon.synchronize {@in_flight}.zero?
    end

    # 捌け切るまで待つ。テストと停止時に使う。返り値は捌け切ったか。
    def idle_after_waiting?(timeout: DRAIN_TIMEOUT)
      deadline = monotonic_now + timeout
      sleep(0.005) while !idle? && monotonic_now < deadline
      return idle?
    end

    # テストと停止時に使う。積まれているぶんが捌けるまで待つ。
    #
    # ⚠ **「キューが空」は「配送が終わった」ではない。**pop された 1 通はまだ
    # ワーカーの中にいる。吐き切りを保証するのは [#stop!] のほう（join まで待つ）。
    def drain!(timeout: DRAIN_TIMEOUT)
      deadline = monotonic_now + timeout
      sleep(0.005) while !@queue.empty? && monotonic_now < deadline
      return nil
    end

    # ⚠⚠ **効いているのは `join` のほう。**`close` の位置ではない ——
    # **`SizedQueue#close` は積まれているものを捨てない**（`pop` は残りを返し切って
    # から nil になる・Ruby 4.0.6 で実測）。⚠ **逆に、`close` しないと新しい push を
    # 受け付け続けてしまう**ので、閉じること自体は必要。
    #
    # ⚠ **`join` まで待つ。**キューが空でも配送中の 1 通が残っているので、そこで
    # 切ると「受け取ったのに届かない」通知になる。待ち上限は [DRAIN_TIMEOUT] で、
    # systemd の `TimeoutStopSec` より短く保つこと。
    def stop!(timeout: DRAIN_TIMEOUT)
      deadline = monotonic_now + timeout
      drain!(timeout: timeout)
      @queue.close
      @threads.each do |thread|
        remaining = deadline - monotonic_now
        thread.join(remaining.positive? ? remaining : 0)
      end
      return nil
    end

    # テスト用。捌け切るまで待ってからスレッドを畳み直す（`stop!` と違い再開できる）。
    def restart_for_test!
      stop!(timeout: 2)
      @queue = SizedQueue.new(@queue.max)
      return start!
    end

    private

    def run_loop
      # ⚠ `close` された SizedQueue の `pop` は、**積まれている残りを返し切ってから**
      # nil を返す（実測）。while で抜けるので、停止時の取り落ちは起きない。
      while (job = @queue.pop)
        deliver_one(job)
      end
    end

    # ⚠⚠ **1 通の失敗でスレッドを死なせない。**死ぬと以降の push が全部キューに
    # 溜まって消える（しかも受信は 202 を返し続けるので**気付けない**）。
    def deliver_one(job)
      @mon.synchronize {@in_flight += 1}
      queued_ms = ((monotonic_now - job.queued_at) * 1000).round
      started = monotonic_now
      result = @deliver.call(job.subscription, job.payload)
      @reporter.record(
        sub: job.subscription, result: result, request_id: job.request_id,
        latency_ms: ((monotonic_now - started) * 1000).round, queued_ms: queued_ms
      )
    rescue StandardError => e
      @reporter.record_exception(
        sub: job.subscription, error: e, request_id: job.request_id,
      )
    ensure
      @mon.synchronize {@in_flight -= 1}
    end

    def monotonic_now
      return Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
