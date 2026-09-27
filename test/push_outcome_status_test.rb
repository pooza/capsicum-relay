require_relative 'support/request_test_case'

# 配送を非同期にしたあとの `/push` の契約 (#55)。
#
# ⚠⚠ **受信と配送が別になったので、HTTP ステータスは「受け取ったか」しか言えない。**
# 配送の結末（success / gone / failed）は観測（ログ・counter）にだけ出る。
#
# ⚠ **`gone` で上流の購読を掃除する経路が変わった。**同期のときは 410 をその場で
# 返していたが、非同期では返す先が無い。代わりに relay 側の行を落とし、**次の
# push が `410 Unknown push token` を返す**ことで掃除される。
class PushOutcomeStatusTest < RequestTestCase
  # `push(device_token:, payload:)` だけを持つ差し替え用クライアント。
  class FakeClient
    attr_reader :calls

    def initialize(result, raises: nil)
      @result = result
      @raises = raises
      @calls = 0
    end

    def push(device_token:, payload:)
      @calls += 1
      raise @raises if @raises

      return @result
    end
  end

  def setup
    super
    @parent = register_subscription
    push_queue.reporter # 触っておく（設定の配線が生きていることの早期検知）
  end

  def push_queue
    return Relay::App.settings.push_queue
  end

  # ⚠⚠ **App は全ケースで共有なので必ず戻す。**
  #
  # ⚠ **`if had` を付けてはいけない。**fixture は apns を持たないので初回の `had` は
  # false で、**復元が丸ごと skip されて偽のクライアントが残る** —— 以降
  # 「未設定なら 503」のケースが**テストの実行順で通ったり落ちたりする**（実際に
  # seed 1 / 777 で踏んだ）。`nil` を入れれば `settings.apns` が nil になり、
  # `push_client_for` は未設定として 503 の経路へ戻る。
  def with_apns(client)
    previous = Relay::BaseApp.settings.respond_to?(:apns) ? Relay::BaseApp.settings.apns : nil
    Relay::BaseApp.set(:apns, client)
    yield
    # ⚠ **配送が終わるまで待つ。**「キューが空」だけでは配送中の 1 通を取り落とす。
    assert(push_queue.idle_after_waiting?(timeout: 5), '配送が捌けなかった')
  ensure
    Relay::BaseApp.set(:apns, previous)
  end

  # ⚠⚠ **毎回 body の長さを変える。**dedup は (push_token, topic, Content-Length)
  # で判定し、窓は 1000ms でプロセス共有 (#16)。同じ長さを続けて送ると 2 通目が
  # `deduped` で 200 になり、**キューまで届かない**（ケースを跨いでも効く）。
  def push(token: @parent['push_token'], body: nil)
    @body_seq = (@body_seq || 0) + 1
    return post(
      "/push/#{token}",
      body || ('x' * @body_seq),
      {'CONTENT_TYPE' => 'application/octet-stream'},
    )
  end

  def outcome_count(outcome, device_type: 'ios')
    return Relay::App.settings.metrics.value(
      'relay_push_total', {device_type: device_type, outcome: outcome}
    )
  end

  # ⚠⚠ **受け取ったら即 202。**200 ではない —— 配送したかはまだ分からない。
  def test_accepted_push_is_accepted
    with_apns(FakeClient.new({success: true})) {push}

    assert_equal(202, last_response.status)
    assert_equal('accepted', json_response['status'])
  end

  def test_delivery_outcome_is_recorded_after_the_response
    with_apns(FakeClient.new({success: true})) {push}

    assert_equal(1, outcome_count('success'))
  end

  # ⚠ 配送が遅くても受信は待たない（非同期にした眼目）。
  def test_receiving_does_not_wait_for_delivery
    slow = Class.new do
      def push(device_token:, payload:)
        sleep 0.3
        return {success: true}
      end
    end.new

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    with_apns(slow) do
      push
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator(elapsed, :<, 0.2, '受信が配送を待っている')
    end
  end

  # ⚠⚠ **`gone` の掃除は「次の push の 410」に置き換わった。**
  def test_gone_removes_the_row_so_the_next_push_is_gone
    with_apns(FakeClient.new({success: false, permanent: true, reason: 'Unregistered'})) do
      push
    end

    assert_equal(202, last_response.status, '1 通目は受け取ってしまう（承知のコスト）')
    assert_nil(database.find_by_push_token(@parent['push_token']), 'relay 側の行が落ちる')

    # 次の push で上流が購読を掃除できる。
    push

    assert_equal(410, last_response.status)
    assert_equal('Unknown push token', json_response['error'])
  end

  # ⚠ 上限超過は購読を残す（#66）。
  def test_oversized_keeps_the_subscription
    with_apns(FakeClient.new({success: false, oversized: true, status: 413})) {push}

    refute_nil(database.find_by_push_token(@parent['push_token']))
    assert_equal(1, outcome_count('oversized'))
  end

  # ⚠ 再試行しない（実測で救えるものがほぼ無い・`PushQueue` の doc）。
  def test_failed_is_not_retried
    client = FakeClient.new({success: false, status: '400', reason: 'INVALID_ARGUMENT'})
    with_apns(client) {push}

    assert_equal(1, client.calls, '再送しない')
    assert_equal(1, outcome_count('failed'))
    refute_nil(database.find_by_push_token(@parent['push_token']), '購読は残す')
  end

  # ⚠⚠ **1 通の例外でワーカーを死なせない。**死ぬと以降の push が全部キューに
  # 溜まって消え、しかも受信は 202 を返し続けるので**気付けない。**
  def test_worker_survives_an_exception
    with_apns(FakeClient.new(nil, raises: ArgumentError.new('boom'))) {push}

    assert_equal(1, outcome_count('exception'))

    ok = FakeClient.new({success: true})
    with_apns(ok) {push}

    assert_equal(1, ok.calls, '次の 1 通が配送されている')
    assert_equal(1, outcome_count('success'))
  end

  # ⚠ クライアント未設定は**同期で 503**。202 に隠れると設定漏れに気付けない。
  def test_unconfigured_client_answers_unavailable_synchronously
    push

    assert_equal(503, last_response.status)
    assert_match('APNs', json_response['error'])
  end

  # ⚠⚠ 満杯は **503**。黙って捨てない。⚠ 4xx にすると購読が消える（#66）。
  def test_queue_full_answers_unavailable
    full = Relay::PushQueue.new(
      deliver: ->(_sub, _payload) {{success: true}},
      reporter: push_queue.reporter,
      capacity: 1,
      workers: 0, # ⚠ ワーカーを立てないので捌けない ＝ 必ず満杯にできる
    )
    previous = Relay::BaseApp.settings.push_queue
    Relay::BaseApp.set(:push_queue, full)
    Relay::BaseApp.set(:apns, FakeClient.new({success: true}))

    push # 1 通目でキューが埋まる

    assert_equal(202, last_response.status)
    push # ⚠ 長さが変わるので dedup を避けられる

    assert_equal(503, last_response.status)
    assert_equal('Push queue full', json_response['error'])
    refute(
      (400..499).cover?(last_response.status),
      '4xx にすると Mastodon が購読を消す（#66）',
    )
    assert_equal(1, outcome_count('rejected'))
  ensure
    Relay::BaseApp.set(:push_queue, previous)
    Relay::BaseApp.set(:apns, nil)
  end

  # ⚠ 停止時にキューを吐き切る（入れないと再起動で通知が消える）。
  #
  # ⚠⚠ **効いているのは `join`。**`SizedQueue#close` は積まれているものを捨てない
  # ので、close の位置を入れ替えてもここは落ちない（実測で確認済み・
  # `PushQueue#stop!` の doc）。**join を外すと落ちる。**
  def test_stop_drains_the_queue
    delivered = []
    queue = Relay::PushQueue.new(
      deliver: lambda do |sub, _payload|
        sleep 0.05
        delivered << sub['id']
        next {success: true}
      end,
      reporter: push_queue.reporter,
      workers: 1,
    ).start!
    3.times {queue.enqueue(subscription: @parent, payload: {})}

    queue.stop!(timeout: 5)

    assert_equal(3, delivered.size, '積まれていたぶんを捌いてから止まる')
  end
end
