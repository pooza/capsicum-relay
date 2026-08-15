require_relative 'support/request_test_case'

# request をまたいだ観測の配線 (#2)。request_id / 構造化ログ / counter / /metrics。
class ObservabilityRouteTest < RequestTestCase
  def setup
    super
    settings.metrics.reset!
    @log = StringIO.new
    Relay::BaseApp.set(:logger, Logger.new(@log, formatter: Relay::StructuredLog::FORMATTER))
  end

  def teardown
    Relay::BaseApp.set(:logger, Logger.new(File::NULL))
  end

  def settings
    return Relay::BaseApp.settings
  end

  # 出力された JSON 行のうち、指定 event のもの。
  def records(event = nil)
    parsed = @log.string.each_line.map {|line| JSON.parse(line)}
    return event ? parsed.select {|r| r['event'] == event} : parsed
  end

  def push_once(token:, headers: {})
    return post(
      "/push/#{token}", 'encrypted-body',
      {'CONTENT_TYPE' => 'application/octet-stream'}.merge(headers)
    )
  end

  ## request_id

  def test_response_carries_a_request_id
    get '/health'

    refute_empty(last_response.headers['X-Request-Id'].to_s)
  end

  # 上流 (nginx) が採番していればそれに乗る。突き合わせの起点を 1 つにするため。
  def test_upstream_request_id_is_honoured
    get('/health', {}, {'HTTP_X_REQUEST_ID' => 'from-nginx'})

    assert_equal('from-nginx', last_response.headers['X-Request-Id'])
  end

  # 1 リクエストの中で id は 1 つ。ログと応答ヘッダが指す先が揃っていないと、
  # journald ↔ capsicum の Sentry breadcrumb の突き合わせができない。
  def test_one_id_per_request
    register_subscription

    ids = records.filter_map {|r| r['request_id']}.uniq

    assert_equal([last_response.headers['X-Request-Id']], ids)
  end

  def test_request_id_is_logged
    register_subscription

    assert_equal(
      last_response.headers['X-Request-Id'], records('register.created').first['request_id']
    )
  end

  ## 構造化ログ

  def test_register_emits_a_structured_event
    register_subscription

    record = records('register.created').first

    assert_equal('ios', record['device_type'])
    assert_equal('alice@example.test', record['account'])
    assert_equal('example.test', record['server'])
    assert_kind_of(Integer, record['latency_ms'])
  end

  # ⚠ 人間向けの文言を同じ行に残す。docs/CLAUDE.md の grep 手順を壊さない。
  def test_human_message_is_kept_in_the_same_line
    register_subscription

    assert_includes(@log.string, 'Registered: alice@example.test (ios')
  end

  def test_push_received_is_logged_with_encoding
    parent = register_subscription
    push_once(token: parent['push_token'], headers: {'HTTP_CONTENT_ENCODING' => 'aes128gcm'})

    record = records('push.received').first

    assert_equal('aes128gcm', record['encoding'])
    assert_equal('ios', record['device_type'])
    # jq で数値比較できるよう整数で出す（Rack は String で返す）。
    assert_equal(14, record['length'])
  end

  # push_token は capability secret。全部はログに残さない。
  def test_push_token_is_fingerprinted_not_logged_in_full
    parent = register_subscription
    push_once(token: parent['push_token'])

    logged = records('push.received').first['push_token']

    refute_equal(parent['push_token'], logged)
    assert_includes(@log.string, logged)
    refute_includes(@log.string, parent['push_token'])
  end

  def test_push_outcome_is_logged_with_latency
    parent = register_subscription
    push_once(token: parent['push_token'])
    push_once(token: parent['push_token'])

    record = records('push.result').first

    assert_equal('deduped', record['outcome'])
    assert_kind_of(Integer, record['latency_ms'])
  end

  ## counter

  def test_register_is_counted
    register_subscription

    assert_equal(1, settings.metrics.value('relay_register_total', {action: 'created'}))
  end

  def test_unregister_is_counted
    sub = register_subscription
    delete("/register/#{sub['id']}", {}, auth_headers)

    assert_equal(1, settings.metrics.value('relay_register_total', {action: 'deleted'}))
  end

  def test_supporter_tip_counts_by_amount
    post_json('/supporters/tip', {account: 'a@b.test', server: 'b.test', count: 3})

    assert_equal(3, settings.metrics.value('relay_supporter_tip_total'))
  end

  def test_push_outcome_is_counted_by_device_type
    parent = register_subscription
    push_once(token: parent['push_token'])
    push_once(token: parent['push_token'])

    assert_equal(
      1, settings.metrics.value('relay_push_total', {device_type: 'ios', outcome: 'deduped'})
    )
  end

  # 失敗しても計上する（母数が見えないと成功率が出せない・#2 の動機そのもの）。
  def test_unconfigured_client_is_counted_as_a_push_attempt
    parent = register_subscription
    push_once(token: parent['push_token'])

    # クライアント未設定の 503 は dispatch より手前で halt するため outcome は
    # 付かないが、受信そのものは push.received に残る。
    assert_equal(503, last_response.status)
    assert_equal(1, records('push.received').size)
  end

  ## /metrics

  def test_metrics_requires_secret
    get '/metrics'

    assert_equal(401, last_response.status)
  end

  def test_metrics_is_prometheus_text
    get('/metrics', {}, auth_headers)

    assert_equal(200, last_response.status)
    assert_match(%r{text/plain}, last_response.headers['content-type'])
    assert_includes(last_response.body, '# TYPE relay_push_total counter')
  end

  def test_metrics_exposes_counters
    register_subscription

    get('/metrics', {}, auth_headers)

    assert_includes(last_response.body, 'relay_register_total{action="created"} 1')
  end

  # gauge は DB から都度読む。counter と違い再起動をまたいで意味を保つ。
  def test_metrics_exposes_gauges_from_the_database
    register_subscription

    get('/metrics', {}, auth_headers)

    assert_includes(last_response.body, "relay_subscriptions 1\n")
  end
end
