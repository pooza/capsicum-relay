require_relative 'entitlement_gate'

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
        extra_preset_hosts: settings.config['extra_preset_hosts'],
      )
      metrics.increment(
        'relay_entitlement_gate_total',
        {route: route, decision: allowed ? 'allow' : 'deny', reason: reason},
      )
      log_gate_decision(subscription, route: route, allowed: allowed, reason: reason)
      return allowed
    end

    # ⚠ **拒んだときと fail-open のときだけ残す。**通常の許可
    # （`enforce_off` / `preset` / `entitled`）は全リクエストに付くので、
    # ログに出すと journald が埋まる。件数は metrics 側にある。
    def log_gate_decision(subscription, route:, allowed:, reason:)
      return if allowed && reason != Relay::EntitlementGate::REASON_ERROR

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
  end
end
