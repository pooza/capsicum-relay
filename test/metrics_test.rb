require_relative 'test_helper'
require 'lib/relay/metrics'

# プロセス内カウンタと Prometheus 露出 (#2)。
class MetricsTest < Minitest::Test
  def setup
    @metrics = Relay::Metrics.new
  end

  def test_counts_by_labels
    @metrics.increment('relay_push_total', {device_type: 'ios', outcome: 'success'})
    @metrics.increment('relay_push_total', {device_type: 'ios', outcome: 'success'})
    @metrics.increment('relay_push_total', {device_type: 'windows', outcome: 'success'})

    assert_equal(2, @metrics.value('relay_push_total', {device_type: 'ios', outcome: 'success'}))
    assert_equal(
      1, @metrics.value('relay_push_total', {device_type: 'windows', outcome: 'success'})
    )
  end

  def test_counts_by_arbitrary_amount
    @metrics.increment('relay_supporter_tip_total', {}, by: 3)

    assert_equal(3, @metrics.value('relay_supporter_tip_total'))
  end

  # ラベルの順序と型（Symbol / String）で別系列にしない。
  def test_label_order_and_type_do_not_split_series
    @metrics.increment('relay_push_total', {device_type: 'ios', outcome: 'success'})
    @metrics.increment('relay_push_total', {'outcome' => 'success', 'device_type' => 'ios'})

    assert_equal(2, @metrics.value('relay_push_total', {outcome: 'success', device_type: 'ios'}))
  end

  def test_unobserved_series_is_zero
    assert_equal(0, @metrics.value('relay_push_total', {device_type: 'ios', outcome: 'failed'}))
  end

  # counter の名前と HELP / TYPE は、まだ 1 件も観測していなくても出す。
  def test_exposes_help_and_type_even_without_samples
    text = @metrics.to_prometheus

    assert_includes(text, '# TYPE relay_push_total counter')
    assert_includes(text, '# HELP relay_push_total')
  end

  def test_renders_samples_with_labels
    @metrics.increment('relay_push_total', {device_type: 'ios', outcome: 'success'})

    assert_includes(
      @metrics.to_prometheus, 'relay_push_total{device_type="ios",outcome="success"} 1'
    )
  end

  def test_renders_labelless_samples
    @metrics.increment('relay_supporter_tip_total')

    assert_includes(@metrics.to_prometheus, "relay_supporter_tip_total 1\n")
  end

  def test_renders_gauges
    text = @metrics.to_prometheus(gauges: {'relay_subscriptions' => ['Registered.', 179]})

    assert_includes(text, '# TYPE relay_subscriptions gauge')
    assert_includes(text, "relay_subscriptions 179\n")
  end

  # ラベル値のエスケープ。壊れた exposition を出すと scrape 全体が落ちる。
  def test_escapes_quotes_in_label_values
    @metrics.increment('relay_push_total', {device_type: 'a"b', outcome: 'success'})

    assert_includes(@metrics.to_prometheus, 'device_type="a\"b"')
  end

  def test_ends_with_a_newline
    assert(@metrics.to_prometheus.end_with?("\n"))
  end

  def test_reset_clears_counters
    @metrics.increment('relay_push_total', {device_type: 'ios', outcome: 'success'})
    @metrics.reset!

    assert_equal(0, @metrics.value('relay_push_total', {device_type: 'ios', outcome: 'success'}))
  end
end
