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

        sub = settings.database.find(params[:id].to_i)
        halt 404, {error: 'Not found'}.to_json unless sub

        # 消す対象を、呼び出し元の端末に縛る (#91)。
        #
        # ⚠⚠ **`X-Device-Id` を送ってこない要求は、まだ従来どおり通す。**出荷済みの
        # capsicum（〜2.0）は送ってこないので、すぐ拒むと古い版の端末が自分の登録を
        # 消せなくなる。⚠ **だからこの照合は、いまは何も守っていない** —— 攻撃する
        # 側はヘッダを省けばよい。拒む時期を決めるための母数を `binding` で数えて
        # おき、`legacy` が減ったら閉じる。
        #
        # ⚠ **食い違いは 404 で返す**（403 にすると、その id に行があると分かる）。
        binding = unregister_binding(sub)
        metrics.increment('relay_unregister_binding_total', {binding: binding})
        halt_unregister_refused!(sub) if binding == 'mismatch'
        halt 404, {error: 'Not found'}.to_json unless remove_registration(sub, binding)

        metrics.increment('relay_register_total', {action: 'deleted'})
        log_event(
          'register.deleted', msg: "Unregistered: #{sub['account']}",
          device_type: sub['device_type'], account: sub['account'],
          server: sub['server'], latency_ms: latency_ms
        )
        # ⚠⚠ **消した行をそのまま返さない** (#91)。行には端末トークンが入っている。
        # この口は連番の id と共有シークレットだけで叩け、共有シークレットはアプリの
        # バイナリから取り出せる前提なので、**id を総当たりすれば、消した行の端末
        # トークンとアカウント名・サーバー名まで読めた**。クライアントは応答の
        # 中身を読んでいない（最初の実装から戻り値が void）ので、id だけ返す。
        {id: sub['id']}.to_json
      end

      helpers do
        def halt_unregister_refused!(sub)
          log_event(
            'register.delete_refused', level: :warn,
            msg: 'Unregister refused: device_id mismatch',
            device_type: sub['device_type'], latency_ms: latency_ms
          )
          halt 404, {error: 'Not found'}.to_json
        end

        # ⚠ **照合に通った回は、照合した `device_id` を条件に付けて消す**（PR #96 の
        # Codex P2）。照合から削除までの間に `/register` が同じ行を別の端末のものへ
        # 差し替えることがあり、ID だけで消すとその登録を消してしまう。
        # 消せなかったら nil。
        def remove_registration(sub, binding)
          if binding == 'matched'
            return settings.database.unregister_owned(sub['id'], sub['device_id'])
          end

          return settings.database.unregister(sub['id'])
        end

        # `DELETE /register/:id` が、行の持ち主から来たかどうか (#91)。
        #
        # - `matched`: 送ってきた `X-Device-Id` が行と一致した
        # - `mismatch`: 食い違った（＝消さない）
        # - `unbound_row`: 行に `device_id` が無い（#15 より前の登録）。照合できない
        # - `legacy`: ヘッダを送ってこない（〜2.0 の capsicum）
        def unregister_binding(sub)
          provided = request.env['HTTP_X_DEVICE_ID'].to_s.strip
          return 'legacy' if provided.empty?

          expected = sub['device_id'].to_s
          return 'unbound_row' if expected.empty?
          return 'matched' if Rack::Utils.secure_compare(expected, provided)

          return 'mismatch'
        end

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
            preset: observed_preset(sub),
            device_tokens: settings.database.entitlement_tokens_for_device(sub['device_id']),
            claimed: claimed.empty? ? nil : settings.database.find_entitlement_token(claimed),
            device_id: sub['device_id'],
            token_sent: !claimed.empty?,
          )
        end

        # ⚠ **端末単位のプリセットはゲートと同じ判定を使う**（#82・PR #83 の Codex P2）。
        # 別に書くと観測とゲートがずれ、止まる人の見積もりが狂う。
        def observed_preset(sub)
          extra = settings.config['extra_preset_hosts']
          return true if Relay::PresetServers.preset?(sub['server'], extra: extra)
          if Relay::EntitlementGate.preset_device?(settings.database, sub['device_id'], extra)
            return Relay::EntitlementObservation::PRESET_DEVICE
          end

          return false
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
