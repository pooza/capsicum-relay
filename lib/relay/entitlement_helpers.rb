require_relative 'entitlement_gate'
require_relative 'preset_servers'
require_relative 'vapid_assertion'

module Relay
  # 認可ゲートを route から呼ぶための helper (capsicum#597 / #60)。
  #
  # ⚠ [Relay::PushHelpers] と同じ形で [Relay::BaseApp] へ `helpers` 登録する。
  # BaseApp に直接書くと行数の上限（RuboCop `Metrics/ClassLength`）に当たる。
  module EntitlementHelpers
    # 有償リレーの認可 (capsicum#597 / #60)。⚠⚠ **既定では何も閉じない。**
    #
    # ⚠ **`/register` と `/push` の両方がここを通る。**2 か所に書くと片方だけ
    # 閉じる形（登録は拒むのに既存の購読は叩き続ける）になる。判定の規則は
    # [Relay::EntitlementGate] が正本。
    #
    # [route] は metrics のラベル（`register` / `push`）。戻り値は許可か。
    def entitlement_allowed?(subscription, route:)
      allowed, reason = Relay::EntitlementGate.decide(
        subscription: subscription,
        database: settings.database,
        preset_verification: preset_verification_for(subscription, route: route),
        extra_preset_hosts: settings.config['extra_preset_hosts'],
      )
      metrics.increment(
        'relay_entitlement_gate_total',
        {route: route, decision: allowed ? 'allow' : 'deny', reason: reason},
      )
      log_gate_decision(subscription, route: route, allowed: allowed, reason: reason)
      return allowed
    end

    # プリセットの名乗りの裏を取る (#69)。
    #
    # ⚠⚠ **enforce の有無に関わらず走らせる。**ゲートを実際に閉じる前に
    # 「本物のプリセットの push が全部 `verified` になるか」を測っておく必要が
    # あり（設計書 2-4「閉じる前に測り直す」）、閉じてから測ると**止めてから
    # 気付く**ことになる。⚠ [Relay::EntitlementGate.decide] は `enforce_off` で
    # 即戻るので、ここで作った判定は**そのとき使われないだけ**。
    #
    # ⚠ **`/register` では検証しない。**あれを叩くのはクライアント自身で、
    # fedi サーバーの署名が存在しない（[Relay::EntitlementGate::PRESET_NOT_CHECKED]）。
    def preset_verification_for(subscription, route:)
      not_checked = Relay::EntitlementGate::PRESET_NOT_CHECKED
      return not_checked unless route == 'push'
      return not_checked unless claims_preset?(subscription)

      assertion = Relay::VapidAssertion.verify(
        authorization: request.env['HTTP_AUTHORIZATION'],
        crypto_key: request.env['HTTP_CRYPTO_KEY'],
        audience: relay_audience,
      )
      verification = classify_preset_claim(subscription['server'], assertion)
      record_vapid_verification(subscription, assertion: assertion, verification: verification)
      return verification
    end

    def claims_preset?(subscription)
      return Relay::PresetServers.preset?(
        subscription['server'], extra: settings.config['extra_preset_hosts']
      )
    end

    # この relay の origin。VAPID の `aud` と突き合わせる (#69)。
    #
    # ⚠⚠ **`aud` を見ないと、他所宛ての署名を貼り直す迂回が通る**
    # （[Relay::VapidAssertion::OUTCOME_AUDIENCE_MISMATCH]）。
    #
    # ⚠ **nginx の前段を見る。**`X-Forwarded-Proto` が無いと `http` を名乗って
    # しまい、**本物の push が全部 audience_mismatch になる。**
    # ⚠ 経路が変則なとき（別名でも受ける等）は設定の `relay_audience` で上書きする。
    def relay_audience
      configured = settings.config['relay_audience']
      return configured unless configured.to_s.strip.empty?

      scheme = request.env['HTTP_X_FORWARDED_PROTO'] || request.scheme
      return "#{scheme}://#{request.host}"
    end

    # ⚠⚠ **順序が意味を持つ。**鍵が引けないときは、署名の有無に関わらず
    # `unavailable`（＝ fail-open）。**こちらが確かめられなかったことを、相手の
    # 落ち度として数えない。**
    def classify_preset_claim(server, assertion)
      expected = settings.vapid_keys&.public_key_for(server)
      return Relay::EntitlementGate::PRESET_UNAVAILABLE if expected.nil?
      return Relay::EntitlementGate::PRESET_UNSIGNED unless assertion.verified?
      return Relay::EntitlementGate::PRESET_VERIFIED if assertion.public_key == expected

      return rotated_or_mismatch(server, assertion)
    end

    # ⚠⚠ **詐称と決める前に、鍵の更新を 1 度だけ疑う (#69・PR #77 の Codex P1)。**
    #
    # プリセットサーバーが VAPID を作り直すと、TTL のあいだ手元は古い鍵のままに
    # なる。そのあいだ本物の push が全部 `mismatch` になり、⚠⚠ **ゲートを閉じて
    # いると 410 を返して上流の購読が永久に消える。**
    #
    # ⚠ **引き直せなかったら fail-open**（`unavailable`）。古い鍵のままで詐称と
    # 決めると、上の事故がそのまま起きる。
    def rotated_or_mismatch(server, assertion)
      fresh = settings.vapid_keys&.refresh_key_for(server)
      return Relay::EntitlementGate::PRESET_UNAVAILABLE if fresh.nil?
      return Relay::EntitlementGate::PRESET_VERIFIED if assertion.public_key == fresh

      return Relay::EntitlementGate::PRESET_MISMATCH
    end

    # ⚠ **`verified` も数える。**分母が無いと「1 件も検証できていない」と
    # 「全部通っている」が区別できない。
    #
    # ⚠⚠ **ラベルは正規化した host にする (#69・PR #77 の Codex P2)。**
    # `subscriptions.server` は **`/register` が受け取った生の申告**で、
    # `MSTDN.B-Shock.org` / `mstdn.b-shock.org.` / 前後の空白がすべて別の値に
    # なる。[claims_preset?] は正規化して比べるので**どれもここまで来る**が、
    # 生のまま数えると ⚠ **その変種の数だけ Prometheus の系列が増え、
    # プロセス内 Hash と `/metrics` の出力が上限なく育つ。**
    def record_vapid_verification(subscription, assertion:, verification:)
      metrics.increment(
        'relay_vapid_verification_total',
        {
          server: Relay::PresetServers.normalize(subscription['server']),
          outcome: assertion.outcome,
          verification: verification.to_s,
        },
      )
      return if verification == Relay::EntitlementGate::PRESET_VERIFIED

      log_vapid_verification(subscription, assertion: assertion, verification: verification)
    end

    # ⚠ **Sentry へは出さない**（`log_event` は journald だけ）。ここは閉じる前の
    # 観測用で、件数は metrics 側にある。
    def log_vapid_verification(subscription, assertion:, verification:)
      log_event(
        'entitlement.vapid',
        level: :warn,
        msg: "Preset claim not verified (#{verification}): #{subscription['server']}",
        verification: verification.to_s,
        outcome: assertion.outcome,
        server: subscription['server'],
        account: subscription['account'],
        # ⚠ 公開鍵は秘密ではないが、行が長くなるので頭だけ。詐称の判別には足りる。
        presented_key: assertion.public_key.to_s[0, 12],
        subject: assertion.subject,
      )
    end

    # ⚠ **拒んだときと fail-open のときだけ残す。**通常の許可
    # （`enforce_off` / `preset` / `entitled`）は全リクエストに付くので、
    # ログに出すと journald が埋まる。件数は metrics 側にある。
    def log_gate_decision(subscription, route:, allowed:, reason:)
      return if allowed && !fail_open?(reason)

      log_event(
        'entitlement.gate',
        # ⚠⚠ fail-open は **warn**。この行が出ているあいだゲートは効いていない。
        level: allowed ? :warn : :info,
        msg: "Entitlement gate #{allowed ? 'failed open' : 'denied'}" \
          " (#{route}): #{subscription['account']}",
        route: route,
        decision: allowed ? 'allow' : 'deny',
        reason: reason,
        account: subscription['account'],
        server: subscription['server'],
        has_device_id: !subscription['device_id'].nil?,
      )
    end

    # 「判定できなかったので通した」形。⚠ **どちらもゲートが効いていない**ので、
    # 許可でもログに残す。
    def fail_open?(reason)
      return [
        Relay::EntitlementGate::REASON_ERROR,
        Relay::EntitlementGate::REASON_PRESET_UNVERIFIABLE,
      ].include?(reason)
    end
  end
end
