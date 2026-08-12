require_relative 'test_helper'
require 'logger'
require 'lib/relay/wns_client'

# #21: WNS Channel URI の host allowlist と送信前の payload サイズチェック。
# いずれも「送る前に弾く」ロジックなので、OAuth / ネットワークに触れずに検査
# できる（短絡した時点で post_raw も access_token も呼ばれない）。
class WnsClientTest < Minitest::Test
  CONFIG = {'wns' => {'package_sid' => 'sid', 'client_secret' => 'secret'}}.freeze
  VALID_URI = 'https://db5p.notify.windows.com/w/?token=abc'.freeze

  # --- valid_channel_uri? (SSRF allowlist) -----------------------------------

  def test_accepts_wns_channel_uri
    assert(Relay::WnsClient.valid_channel_uri?(VALID_URI))
    assert(Relay::WnsClient.valid_channel_uri?('https://sg2p.notify.windows.com/?x=1'))
  end

  # region 付きサブドメインが実 URI の形。bare host は実在しないので弾いてよい。
  def test_rejects_bare_wns_host
    refute(Relay::WnsClient.valid_channel_uri?('https://notify.windows.com/w/'))
  end

  def test_rejects_non_wns_host
    refute(Relay::WnsClient.valid_channel_uri?('https://evil.example.com/w/'))
  end

  # notify.windows.com.evil.com のような suffix なりすましを弾く。
  def test_rejects_lookalike_host
    refute(Relay::WnsClient.valid_channel_uri?('https://notify.windows.com.evil.com/w/'))
  end

  def test_rejects_plain_http
    refute(Relay::WnsClient.valid_channel_uri?('http://db5p.notify.windows.com/w/'))
  end

  def test_rejects_blank_and_garbage
    refute(Relay::WnsClient.valid_channel_uri?(nil))
    refute(Relay::WnsClient.valid_channel_uri?(''))
    refute(Relay::WnsClient.valid_channel_uri?('not a uri'))
  end

  # --- push pre-checks（ネットワーク非依存で短絡すること） --------------------

  def test_push_rejects_invalid_channel_uri_without_network
    client = build_client
    result = client.push(device_token: 'https://evil.example.com/x', payload: {'a' => 1})

    refute(result[:success])
    assert_equal('invalid_channel_uri', result[:reason])
    refute(result[:permanent])
    refute(result[:oversized])
  end

  def test_push_rejects_oversized_payload_before_sending
    client = build_client
    payload = {'body' => 'x' * (Relay::WnsClient::RAW_PAYLOAD_LIMIT + 1)}
    result = client.push(device_token: VALID_URI, payload: payload)

    refute(result[:success])
    assert_equal(Relay::WnsClient::OVERSIZED_STATUS, result[:status])
    assert(result[:oversized])
    refute(result[:permanent])
  end

  private

  def build_client
    return Relay::WnsClient.new(CONFIG, logger: Logger.new(File::NULL))
  end
end
