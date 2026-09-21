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

  # 暗号化キーを持たない payload（お知らせ等）は degrade で落とすものが無いので、
  # 従来どおり POST せずに 413 経路へ倒す (#21)。⚠ #65 以前はこのテストが
  # `body` キーで超過させていたが、それは今は degrade 側へ進む。
  def test_push_rejects_oversized_payload_without_encrypted_keys_before_sending
    client = build_client
    payload = {'announcement_body' => 'x' * (Relay::WnsClient::RAW_PAYLOAD_LIMIT + 1)}
    result = client.push(device_token: VALID_URI, payload: payload)

    refute(result[:success])
    assert_equal(Relay::WnsClient::OVERSIZED_STATUS, result[:status])
    assert(result[:oversized])
    refute(result[:permanent])
  end

  # --- 上限超過の degrade (#65) ------------------------------------------------

  # ⚠⚠ **本丸。**暗号化 body で 5000B を超えた通知を、body を落として送る。以前は
  # 413 で 1 通まるごと drop していた（Windows の端末に何も出ない）。
  def test_oversized_encrypted_payload_is_degraded_and_sent
    pool = RecordingPool.new
    result = build_client(pool).push(device_token: VALID_URI, payload: oversized_encrypted_payload)

    assert(result[:success], 'drop せずに送れている')
    assert(result[:degraded], '上位が handle_push_degraded へ振り分けられる')
    assert_operator(result[:original_size], :>, Relay::WnsClient::RAW_PAYLOAD_LIMIT)
    assert_equal(1, pool.requests.size, '送信は 1 回だけ')
  end

  def test_degraded_body_drops_encrypted_keys_and_keeps_routing_keys
    pool = RecordingPool.new
    build_client(pool).push(device_token: VALID_URI, payload: oversized_encrypted_payload)
    sent = JSON.parse(pool.requests.first.body)

    Relay::WnsClient::ENCRYPTED_KEYS.each do |key|
      refute(sent.key?(key), "#{key} を落としている")
    end
    assert_equal('mstdn.example', sent['server'])
    assert_equal('alice@mstdn.example', sent['account'], '表示と鍵選びに使う account は残す')
    assert_equal('1', sent['degraded'])
    assert_operator(pool.requests.first.body.bytesize, :<=, Relay::WnsClient::RAW_PAYLOAD_LIMIT)
  end

  # ⚠⚠ capsicum の Windows 受信側 (web_push_receive.cpp の ParseFlatObject) は
  # **値が文字列でないキーが 1 つでもあるとエンベロープ全体を捨てる**。目印を
  # `true` にすると汎用文面すら出ない。
  def test_degraded_body_values_are_all_strings
    pool = RecordingPool.new
    build_client(pool).push(device_token: VALID_URI, payload: oversized_encrypted_payload)
    sent = JSON.parse(pool.requests.first.body)

    sent.each do |key, value|
      assert_kind_of(String, value, "#{key} の値が文字列でない（capsicum が全体を捨てる）")
    end
  end

  # 上限以下はこれまでどおり手を付けない（目印も付けない）。
  def test_payload_within_limit_is_sent_untouched
    pool = RecordingPool.new
    payload = oversized_encrypted_payload.merge('body' => 'x' * 100)
    result = build_client(pool).push(device_token: VALID_URI, payload: payload)

    assert(result[:success])
    refute(result[:degraded])
    assert_equal(payload.to_json, pool.requests.first.body)
  end

  # degrade して送ったが WNS が失敗を返したときは、degraded を付けない（上位が
  # 「汎用文面を届けた」と誤って数えないように）。
  def test_degraded_flag_is_not_attached_to_failures
    pool = RecordingPool.new(status: 500)
    result = build_client(pool).push(device_token: VALID_URI, payload: oversized_encrypted_payload)

    refute(result[:success])
    refute(result[:degraded])
  end

  # 落とすキーは APNs の degrade (#17) と同じ集合。片方だけ増やすと、WNS だけ
  # 中途半端な暗号化キーを残す（capsicum 側で「暗号化通知」と誤判定される）。
  def test_encrypted_keys_match_apns_payload
    require 'lib/relay/apns_payload'

    assert_equal(Relay::ApnsPayload::ENCRYPTED_KEYS, Relay::WnsClient::ENCRYPTED_KEYS)
  end

  private

  # WNS への POST を受け止めて記録するプール。OAuth とネットワークには触らない。
  class RecordingPool
    attr_reader :requests

    def initialize(status: 200)
      @status = status
      @requests = []
    end

    def checkout(_host, _port)
      return [self, false]
    end

    def checkout_fresh(_host, _port)
      return self
    end

    def checkin(_host, _port, _http)
      return nil
    end

    def discard(_http)
      return nil
    end

    def close_all
      return 0
    end

    def request(req)
      @requests << req
      code = @status.to_s
      res = Net::HTTPResponse.send(:response_class, code).new('1.1', code, 'OK')
      res['X-WNS-NotificationStatus'] = 'received' if @status == 200
      return res
    end
  end

  def oversized_encrypted_payload
    return {
      'body' => 'x' * (Relay::WnsClient::RAW_PAYLOAD_LIMIT + 1),
      'encoding' => 'aes128gcm',
      'crypto_key' => 'dh=abc',
      'encryption' => 'salt=def',
      'server' => 'mstdn.example',
      'account' => 'alice@mstdn.example',
    }
  end

  # pool を渡したときは、キャッシュ済みトークンを埋めて OAuth を叩かせない。
  def build_client(pool = nil)
    client = Relay::WnsClient.new(CONFIG, logger: Logger.new(File::NULL), pool: pool)
    if pool
      client.instance_variable_set(:@access_token, 'token')
      client.instance_variable_set(:@token_expires_at, Time.now + 3600)
    end
    return client
  end
end
