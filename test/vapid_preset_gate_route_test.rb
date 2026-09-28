require_relative 'support/request_test_case'
require 'base64'
require 'jwt'
require 'openssl'
require 'relay/vapid_key_ledger'

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
    def public_key_for(host) = @keys[Relay::PresetServers.normalize(host)]
    # 引き直しても同じ鍵（更新していない）。
    def refresh_key_for(host) = public_key_for(host)
  end

  # 手元は [cached]、引き直すと [fresh] を返す代役（鍵の更新の再現）。
  # [fresh] が nil なら「引き直せなかった」。
  class RotatingDirectory
    def initialize(host, cached, fresh)
      @host = Relay::PresetServers.normalize(host)
      @cached = cached
      @fresh = fresh
    end

    def public_key_for(host)
      return Relay::PresetServers.normalize(host) == @host ? @cached : nil
    end

    def refresh_key_for(host)
      return Relay::PresetServers.normalize(host) == @host ? @fresh : nil
    end
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

  # ⚠ 設定を一時的に外す（設定漏れの挙動を見るため）。⚠ **必ず戻す。**
  def without_relay_audience
    config = Relay::BaseApp.settings.config
    previous = config.delete('relay_audience')
    yield
  ensure
    config['relay_audience'] = previous unless previous.nil?
  end

  def encode(key)
    return Base64.urlsafe_encode64(key.public_key.to_octet_string(:uncompressed)).delete('=')
  end

  # ⚠ Rack::Test は `example.org` を名乗り、`X-Forwarded-Proto` は無いので
  # relay が組む audience は `http://example.org` になる（#69・Codex P1）。
  AUDIENCE = 'http://example.org'.freeze

  def vapid_header(key, audience: AUDIENCE)
    payload = {
      aud: audience,
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
  def push_claiming_preset(authorization: nil, extra_headers: {})
    push_token = register_subscription(
      token: 'device-token', device_type: 'ios', account: "alice@#{PRESET}", server: PRESET,
    )['push_token']
    headers = {'CONTENT_TYPE' => 'application/octet-stream'}.merge(extra_headers)
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

  # ⚠⚠ **他所宛ての署名を貼り直しても通らない（#69・Codex P1）。**
  #
  # 攻撃者がプリセットサーバーで購読を作って**自分のサーバー宛て**の本物の
  # `Authorization` を受け取り、それを期限内にここへ貼り直す経路。鍵の照合
  # だけでは通ってしまう。
  def test_a_signature_for_another_audience_is_gone
    with_enforce do
      assert_equal(
        410,
        push_claiming_preset(
          authorization: vapid_header(@key, audience: 'https://attacker.example'),
        ),
      )
    end
  end

  # ⚠⚠ **期待値をリクエストから作らない（#69・Codex P1 2 巡目）。**
  #
  # Rack の `request.host` は **`X-Forwarded-Host` を見る**うえ、
  # nginx.conf.sample はそのヘッダを消していない。期待値を組んでいた版では、
  # **攻撃者が自分宛ての本物の署名に `X-Forwarded-Host` を添えるだけで、
  # 期待値ごと攻撃者の値になって素通りした。**
  # ⚠⚠ **歯の確認: `relay_audience` を外して、旧実装が通していた形をそのまま送る。**
  # 設定が在るケースは [test_a_signature_for_another_audience_is_gone] が見ている
  # ので、ここで突くのは**設定が無いときにヘッダから組んでいた**ところ。
  def test_a_forwarded_host_cannot_move_the_expected_audience
    without_relay_audience do
      push_claiming_preset(
        authorization: vapid_header(@key, audience: 'https://attacker.example'),
        extra_headers: {
          'HTTP_X_FORWARDED_HOST' => 'attacker.example',
          'HTTP_X_FORWARDED_PROTO' => 'https',
          'HTTP_HOST' => 'attacker.example',
        },
      )
    end

    # ⚠⚠ **旧実装ではここが `verified` だった**（期待値ごと攻撃者の値になった）。
    assert_equal(
      0,
      metrics.value('relay_vapid_verification_total',
        {server: PRESET, outcome: 'verified', verification: 'verified'}),
    )
  end

  # ⚠⚠ **設定漏れを「鍵が引けない」と混ぜない。**混ぜると、ゲートが効いて
  # いないことに気付けなくなる。
  def test_a_missing_audience_is_recorded_with_its_own_outcome
    without_relay_audience {push_claiming_preset(authorization: vapid_header(@key))}

    assert_equal(
      1,
      metrics.value('relay_vapid_verification_total',
        {server: PRESET, outcome: 'audience_unconfigured', verification: 'unavailable'}),
    )
  end

  # ⚠ 設定漏れでも本物を止めない（fail-open）。
  def test_a_missing_audience_fails_open
    without_relay_audience do
      with_enforce do
        refute_equal(410, push_claiming_preset(authorization: vapid_header(@key)))
      end
    end
  end

  # ⚠⚠ **鍵の更新を詐称と誤らない（#69・Codex P1）。**
  #
  # 誤ると 410 を返して**上流の購読が永久に消える**ので、取り返しがつかない。
  def test_a_rotated_key_is_picked_up_instead_of_being_called_impersonation
    rotated = OpenSSL::PKey::EC.generate('prime256v1')
    # 手元は古い鍵のまま。引き直すと新しい鍵が返る。
    Relay::BaseApp.set(
      :vapid_keys, RotatingDirectory.new(PRESET, encode(@key), encode(rotated))
    )

    with_enforce do
      refute_equal(410, push_claiming_preset(authorization: vapid_header(rotated)))
    end
  end

  # ⚠ 引き直せなかったら fail-open（古い鍵のままで詐称と決めない）。
  def test_fails_open_when_the_refresh_cannot_reach_the_server
    Relay::BaseApp.set(
      :vapid_keys, RotatingDirectory.new(PRESET, encode(@key), nil)
    )

    with_enforce do
      refute_equal(410, push_claiming_preset(authorization: vapid_header(@other)))
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

  # ⚠⚠ **ラベルは正規化した host（#69・Codex P2）。**生の申告のまま数えると、
  # 大小・末尾のドット・空白の変種の数だけ系列が増えて上限なく育つ。
  def test_the_metric_label_is_the_normalized_host
    push_token = register_subscription(
      token: 'device-token', device_type: 'ios',
      account: "alice@#{PRESET}", server: "  #{PRESET.upcase}.  "
    )['push_token']
    post("/push/#{push_token}", 'body', {'CONTENT_TYPE' => 'application/octet-stream'})

    assert_equal(
      1,
      metrics.value('relay_vapid_verification_total',
        {server: PRESET, outcome: 'absent', verification: 'unsigned'}),
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

  # --- ⚠⚠ 6 巡目の Codex P1（競合を fail-open にしていた） ---------------

  # 手元は @key、引き直すと競合（BUSY）を返す代役。
  class BusyDirectory
    def initialize(host, cached)
      @host = Relay::PresetServers.normalize(host)
      @cached = cached
    end

    def public_key_for(host)
      return Relay::PresetServers.normalize(host) == @host ? @cached : nil
    end

    def refresh_key_for(_host) = Relay::VapidKeyLedger::BUSY
  end

  # ⚠⚠ **競合を fail-open にすると、同時リクエストを撃つだけで確定的に
  # ゲートを抜けられる。**1 本目が枠を取り、2 本目が「外部障害」として通る形。
  #
  # ⚠ **410 でもない**（購読が永久に消える）。**503 で再試行させる。**
  #
  # ⚠⚠ **ステータスだけで見ない。**fixture は apns 未設定なので、**素通りしても
  # 503 になる**（`ensure_push_client!`）。本文の `reason` で区別する。
  def test_a_busy_verification_is_503_not_allowed
    Relay::BaseApp.set(:vapid_keys, BusyDirectory.new(PRESET, encode(@key)))

    with_enforce do
      # 別の鍵で署名 → 引き直しへ入る → 競合。
      assert_equal(503, push_claiming_preset(authorization: vapid_header(@other)))
    end

    assert_equal('busy', json_response['reason'])
  end

  # ⚠ 上流に再送させるための手掛かりを付ける。
  def test_a_busy_verification_asks_for_a_retry
    Relay::BaseApp.set(:vapid_keys, BusyDirectory.new(PRESET, encode(@key)))
    with_enforce {push_claiming_preset(authorization: vapid_header(@other))}

    assert_equal('1', last_response.headers['Retry-After'])
  end

  # ⚠ 理由を `unverifiable`（外部障害）に溶かさない。
  def test_busy_is_recorded_separately_from_an_external_failure
    Relay::BaseApp.set(:vapid_keys, BusyDirectory.new(PRESET, encode(@key)))
    with_enforce {push_claiming_preset(authorization: vapid_header(@other))}

    assert_equal(
      1,
      metrics.value('relay_vapid_verification_total',
        {server: PRESET, outcome: 'verified', verification: 'busy'}),
    )
    assert_equal(
      0,
      metrics.value('relay_entitlement_gate_total',
        {route: 'push', decision: 'allow', reason: 'preset_unverifiable'}),
    )
  end

  # ⚠⚠ **既定（enforce off）では 503 にしない。**ゲートが何も閉じていないのに
  # 裏取りの競合だけで push を弾いたら、それこそ実害になる。
  #
  # ⚠ 素通りしても apns 未設定で 503 になるので、**本文で区別する。**
  def test_a_busy_verification_does_not_reject_when_enforce_is_off
    Relay::BaseApp.set(:vapid_keys, BusyDirectory.new(PRESET, encode(@key)))
    push_claiming_preset(authorization: vapid_header(@other))

    refute_equal('busy', json_response['reason'])
  end

  # --- ⚠⚠ 7 巡目の Codex（間隔の中の不一致を 410 にしていた） -------------

  # ⚠⚠ **引いた 60 秒の間に鍵が更新されると、本物が詐称扱いになっていた。**
  #
  # 手元は古い鍵、引き直しは間隔の中なので走らない —— そこで「引き直した結果と
  # 一致しない」と読んで **410 で購読を永久に消していた。**⚠ 正解は **503**
  # （いま確認できないので、もう一度送ってくれ）。
  def test_a_mismatch_inside_the_throttle_window_is_retryable
    Relay::BaseApp.set(:vapid_keys, BusyDirectory.new(PRESET, encode(@key)))

    with_enforce do
      refute_equal(410, push_claiming_preset(authorization: vapid_header(@other)))
    end

    assert_equal('busy', json_response['reason'])
  end

  # ⚠ 二重計上しない（#69・Codex P2 7 巡目）。⚠⚠ **濁ると「ゲートを閉じてよいか」
  # を測る材料にならない。**
  def test_a_busy_request_is_counted_once
    Relay::BaseApp.set(:vapid_keys, BusyDirectory.new(PRESET, encode(@key)))
    with_enforce {push_claiming_preset(authorization: vapid_header(@other))}

    assert_equal(
      1,
      metrics.value('relay_entitlement_gate_total',
        {route: 'push', decision: 'deny', reason: 'preset_busy'}),
    )
    assert_equal(
      0,
      metrics.value('relay_entitlement_gate_total',
        {route: 'push', decision: 'busy', reason: 'preset_busy'}),
      '同じ要求を 2 回数えない',
    )
  end
end
