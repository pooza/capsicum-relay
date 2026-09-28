require_relative '../base_app'
require_relative '../entitlement_observation'
require_relative '../preset_servers'
require_relative '../wns_client'

module Relay
  module Routes
    # 端末トークンの登録 / 解除。capsicum の PushRegistrationService が叩く。
    class Register < BaseApp
      DEVICE_TYPES = ['ios', 'android', 'macos', 'windows'].freeze

      post '/register' do
        authenticate!
        require_fields!('token', 'device_type', 'account', 'server')
        validate_device_type!

        # device_id は任意。送ってこない旧クライアントは従来どおり token をキーに
        # 登録される (#15 / capsicum#932)。
        sub = settings.database.register(
          token: json_body['token'],
          device_type: json_body['device_type'],
          account: json_body['account'],
          server: json_body['server'],
          device_id: json_body['device_id'],
        )
        # 利用権の観測 (capsicum#597 / #59)。⚠⚠ **ここでは何も拒まない。**
        observation = observe_entitlement(sub)
        record_registration(sub, observation)

        # 認可 (capsicum#597 / #60)。⚠⚠ **既定では何も閉じない。**
        #
        # ⚠ **登録してから判定する。**行を作らずに拒むと、⚠ **フェーズ 3 で
        # ゲートを閉じた瞬間に「誰が止まったか」が DB から分からなくなる**
        # （観測 #59 の母数が消える）。行は残し、配送を `/push` で止める。
        allowed, = entitlement_decision(sub, route: 'register')
        halt_entitlement_required! unless allowed

        status 201
        sub.to_json
      end

      delete '/register/:id' do
        authenticate!

        sub = settings.database.unregister(params[:id].to_i)
        halt 404, {error: 'Not found'}.to_json unless sub

        metrics.increment('relay_register_total', {action: 'deleted'})
        log_event(
          'register.deleted', msg: "Unregistered: #{sub['account']}",
          device_type: sub['device_type'], account: sub['account'],
          server: sub['server'], latency_ms: latency_ms
        )
        sub.to_json
      end

      helpers do
        # ⚠ **401 と区別できる形で返す。**クライアントは「シークレットが違う」と
        # 「利用権が無い」で出す文面が違う（capsicum#1123 の登録ステータス画面）。
        def halt_entitlement_required!
          halt 403, {
            error: 'Entitlement required', reason: 'entitlement_required'
          }.to_json
        end

        def record_registration(sub, observation)
          metrics.increment('relay_register_total', {action: 'created'})
          metrics.increment('relay_register_entitlement_total', observation)
          log_event(
            'register.created',
            msg: "Registered: #{sub['account']} (#{sub['device_type']}," \
              " device_id=#{sub['device_id'] ? 'yes' : 'none'})",
            device_type: sub['device_type'],
            account: sub['account'],
            server: sub['server'],
            has_device_id: !sub['device_id'].nil?,
            # ⚠ **`server` は既に上の行に出ている**ので、プリセットかどうかが
            # 食い違っていたら（一覧のズレ）ログだけで気付ける。
            preset: observation[:preset],
            entitlement: observation[:entitlement],
            entitlement_token: observation[:token],
            latency_ms: latency_ms,
          )
        end

        # この登録が「非プリセット かつ 利用権なし」かを言えるようにする (#59)。
        #
        # ⚠⚠ **判定はしない。**フェーズ 3 でゲートを閉じたときに誰が影響を受けるかを
        # 先に知るための記録で、⚠ **戻り値は metrics のラベル**なので値の集合を
        # 小さく保つ（`server` や `account` を混ぜない）。
        #
        # ⚠ **利用権は `subscriptions.device_id` から引く**（設計書 2-4 の経路）。
        # クライアントが送ってきた token をそのまま信じるのではなく、**ゲートが
        # 実際に通る経路で引く**ことに意味がある —— 送れているのに引けない端末
        # （[Relay::EntitlementObservation::TOKEN_MISMATCH]）を見つけられる。
        def observe_entitlement(sub)
          claimed = json_body['entitlement_token'].to_s
          return Relay::EntitlementObservation.classify(
            preset: Relay::PresetServers.preset?(
              sub['server'], extra: settings.config['extra_preset_hosts']
            ),
            device_tokens: settings.database.entitlement_tokens_for_device(sub['device_id']),
            claimed: claimed.empty? ? nil : settings.database.find_entitlement_token(claimed),
            device_id: sub['device_id'],
            token_sent: !claimed.empty?,
          )
        end

        def validate_device_type!
          unless DEVICE_TYPES.include?(json_body['device_type'])
            halt 400, {error: 'device_type must be ios, android, macos or windows'}.to_json
          end

          # windows の token は WNS Channel URI。任意ホストを保存すると /push で
          # そこへ Bearer + payload 付き POST をさせられる (SSRF) ため、入口で WNS
          # ホストに限定する (#21 / capsicum#474 レビュー)。
          return unless json_body['device_type'] == 'windows'
          return if Relay::WnsClient.valid_channel_uri?(json_body['token'])

          halt 400, {error: 'token must be a WNS channel URI (*.notify.windows.com)'}.to_json
        end
      end
    end
  end
end
