require_relative 'test_helper'
require 'json'
require 'lib/relay/structured_log'

# 構造化ログの 1 行フォーマット (#2)。
#
# ⚠ ヘルパを `format` と名付けない。`Kernel#format` と衝突し、rubocop -a が
# `Style/RedundantFormat` で `'x' % {...}` に書き換えてテストを壊す（実際に踏んだ）。
class StructuredLogTest < Minitest::Test
  TIME = Time.utc(2026, 8, 16, 1, 2, 3)

  def line_for(message, severity: 'INFO')
    return Relay::StructuredLog::FORMATTER.call(severity, TIME, nil, message)
  end

  def record_for(message, severity: 'INFO')
    return JSON.parse(line_for(message, severity: severity))
  end

  def test_emits_one_json_object_per_line
    line = line_for('hello')

    assert_equal(1, line.count("\n"))
    assert(line.end_with?("\n"))
  end

  def test_includes_timestamp_and_level
    record = record_for('hello')

    assert_equal('2026-08-16T01:02:03.000Z', record['ts'])
    assert_equal('INFO', record['level'])
  end

  # 未計装の呼び出し（logger.info("...")）も JSON になる。
  def test_string_message_becomes_msg
    assert_equal('hello', record_for('hello')['msg'])
  end

  def test_hash_message_is_expanded
    record = record_for({event: 'push.result', outcome: 'success', latency_ms: 12})

    assert_equal('push.result', record['event'])
    assert_equal('success', record['outcome'])
    assert_equal(12, record['latency_ms'])
  end

  # ⚠ 人間向けの 1 行を捨てない。docs/CLAUDE.md「配信不達の切り分け」の
  # grep 手順が JSON 化で死なないための条件。
  def test_human_message_survives_grep
    line = line_for({event: 'push.result', msg: 'Pushed to windows: a@b'})

    assert_includes(line, 'Pushed to windows: a@b')
  end

  # nil の項目は落として行を短くする。
  def test_nil_fields_are_dropped
    record = record_for({event: 'push.result', latency_ms: nil})

    refute(record.key?('latency_ms'))
  end

  def test_level_is_taken_from_severity
    assert_equal('WARN', record_for('x', severity: 'WARN')['level'])
  end

  # token は capability secret。全部は残さない。
  def test_fingerprint_masks_the_middle
    assert_equal('abcdef…wxyz', Relay::StructuredLog.fingerprint('abcdefghijklmnopqrstuvwxyz'))
  end

  def test_fingerprint_fully_masks_short_tokens
    assert_equal('*' * 6, Relay::StructuredLog.fingerprint('abcdef'))
  end

  def test_fingerprint_of_nil_is_nil
    assert_nil(Relay::StructuredLog.fingerprint(nil))
  end
end
