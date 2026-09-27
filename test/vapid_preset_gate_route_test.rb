require_relative 'support/request_test_case'
require 'base64'
require 'jwt'
require 'openssl'

# プリセットの名乗りを `/push` の VAPID 署名で裏取りする (capsicum#597 / #69)。
#
# ⚠⚠ **この Issue の眼目は「アカウントを作らずにプリセットを名乗れる」ことを
# 塞ぐこと。**「プリセットに 1 アカウント持てば全部無償」の穴そのものは
# **完全に意図通り**で残す（設計書 1-2 / 未決事項 3）。
#
# ⚠ **ここで固定したいのは 4 点。**
#
# 1. ⚠⚠ **署名が無ければプリセットの近道は使えない**（付けないだけで迂回できて
#    しまうと、直したことにならない）
# 2. ⚠⚠ **別の鍵の署名も通らない**
# 3. ⚠ **鍵が引けないときは通す**（fail-open・こちらの障害で本物を止めない）
# 4. ⚠ **既定（enforce off）では 1mm も変わらない**
class VapidPresetGateRouteTest < RequestTestCase
  PRESET = 'mstdn.b-shock.org'.freeze

  # `public_key_for` だけを持つ最小の代役。[keys] は host => 鍵（nil で「引けない」）。
  class FakeDirectory
    def initialize(keys) = @keys = keys
    def public_key_for(host) = @keys[host.to_s.downcase]
  end

  # ⚠⚠ **`Relay::BaseApp` に set する。** route は `Relay::Routes::*` という
  # **App の兄弟クラス**なので、`Relay::App.set` では見えない（2026-09-28 に
  # 踏んだ —— 差し替えたつもりで本物のディレクトリが動き、テストが
  # `mstdn.b-shock.org` を実際に叩いていた）。
  def setup
    super
    @key = OpenSSL::PKey::EC.generate('prime256v1')
    @other = OpenSSL::PKey::EC.generate('prime256v1')
    @previous_directory = Relay::BaseApp.settings.vapid_keys
    stub_directory({PRESET => encode(@key)})
  end

  def teardown
    Relay::BaseApp.set(:vapid_keys, @previous_directory)
    super
  end

  def stub_directory(keys)
    Relay::BaseApp.set(:vapid_keys, FakeDirectory.new(keys))
  end

  def encode(key)
    return Base64.urlsafe_encode64(key.public_key.to_octet_string(:uncompressed)).delete('=')
  end

  def vapid_header(key)
    payload = {
      aud: 'https://relay.capsicum.shrieker.net',
      exp: Time.now.to_i + 3600,
      sub: 'mailto:ops@example.test',
    }
    return "vapid t=#{JWT.encode(payload, key, 'ES256', typ: 'JWT')},k=#{encode(key)}"
  end

  def metrics
    return Relay::App.settings.metrics
  end

  # ⚠ **env を戻す。**戻さないと後続のテストが「閉じた」状態で走る。
  def with_enforce
    previous = ENV.fetch('RELAY_ENTITLEMENT_ENFORCE', nil)
    ENV['RELAY_ENTITLEMENT_ENFORCE'] = 'true'
    yield
  ensure
    if previous.nil?
      ENV.delete('RELAY_ENTITLEMENT_ENFORCE')
    else
      ENV['RELAY_ENTITLEMENT_ENFORCE'] = previous
    end
  end

  # プリセットを名乗る購読を 1 件作り、そこへ push する。
  def push_claiming_preset(authorization: nil)
    push_token = register_subscription(
      token: 'device-token', device_type: 'ios', account: "alice@#{PRESET}", server: PRESET,
    )['push_token']
    headers = {'CONTENT_TYPE' => 'application/octet-stream'}
    headers['HTTP_AUTHORIZATION'] = authorization if authorization
    post("/push/#{push_token}", 'body', headers)
    return last_response.status
  end

  # --- 閉じた側（enforce on） ---------------------------------------------

  # ⚠⚠ **#69 が塞ぐ穴そのもの。**サーバー名を打っただけの購読は、署名が無いので
  # プリセットの近道を使えず、利用権も無いので 410 になる。
  def test_unsigned_preset_claim_is_gone
    with_enforce do
      assert_equal(410, push_claiming_preset)
    end
  end

  # ⚠⚠ **別のサーバーの鍵で署名しても通らない。**
  def test_a_signature_from_another_key_is_gone
    with_enforce do
      assert_equal(410, push_claiming_preset(authorization: vapid_header(@other)))
    end
  end

  # ⚠ **本物は通る。**ここが落ちると、プリセットの通知を止めてしまう。
  def test_a_matching_signature_passes_the_gate
    with_enforce do
      # apns は fixture で未設定なので 503 まで進む。⚠ **410 でない**ことが要点。
      refute_equal(410, push_claiming_preset(authorization: vapid_header(@key)))
    end
  end

  # ⚠⚠ **鍵が引けないのは「こちらの障害」。**本物のプリセットを巻き込まない。
  def test_fails_open_when_the_key_cannot_be_fetched
    stub_directory({})

    with_enforce do
      refute_equal(410, push_claiming_preset)
    end
  end

  # ⚠ 通したことに気付けるよう理由を分ける。
  def test_fail_open_is_recorded_with_its_own_reason
    stub_directory({})
    with_enforce {push_claiming_preset}

    assert_equal(
      1,
      metrics.value('relay_entitlement_gate_total',
        {route: 'push', decision: 'allow', reason: 'preset_unverifiable'}),
    )
  end

  # ⚠ 拒否の理由を `no_entitlement` に溶かさない。
  def test_the_denial_names_the_preset_failure
    with_enforce {push_claiming_preset}

    assert_equal(
      1,
      metrics.value('relay_entitlement_gate_total',
        {route: 'push', decision: 'deny', reason: 'preset_unsigned'}),
    )
  end

  # --- 既定（enforce off）＝挙動不変 --------------------------------------

  # ⚠⚠ **いちばん大事な固定。**署名が無くても、既定では何も変わらない。
  def test_unsigned_preset_claim_is_unchanged_by_default
    refute_equal(410, push_claiming_preset)
  end

  # --- 観測（閉じる前に測るための系列） -----------------------------------

  # ⚠⚠ **enforce の有無に関わらず数える。**閉じてから測ると**止めてから気付く**。
  def test_verification_is_recorded_even_when_the_gate_is_open
    push_claiming_preset(authorization: vapid_header(@key))

    assert_equal(
      1,
      metrics.value('relay_vapid_verification_total',
        {server: PRESET, outcome: 'verified', verification: 'verified'}),
    )
  end

  def test_an_unsigned_claim_is_recorded_as_absent
    push_claiming_preset

    assert_equal(
      1,
      metrics.value('relay_vapid_verification_total',
        {server: PRESET, outcome: 'absent', verification: 'unsigned'}),
    )
  end

  # ⚠ 非プリセットの購読では検証しない（鍵を引きに行くこと自体が無駄）。
  def test_non_preset_subscriptions_are_not_verified
    push_token = register_subscription(
      token: 'device-token', device_type: 'ios',
      account: 'bob@mastodon.social', server: 'mastodon.social'
    )['push_token']
    post("/push/#{push_token}", 'body', {'CONTENT_TYPE' => 'application/octet-stream'})

    assert_equal(
      0,
      metrics.value('relay_vapid_verification_total',
        {server: 'mastodon.social', outcome: 'absent', verification: 'unsigned'}),
    )
  end
end
