require_relative '../base_app'
require_relative '../sentry_setup'

module Relay
  module Routes
    # Mastodon / Misskey からの Web Push 受け口。
    #
    # ⚠ **この route だけ認証が無い。** 上流の SNS が叩くので共有シークレットを
    # 持たせられず、push_token そのものが capability になっている。
    class Push < BaseApp
      post '/push/:push_token' do
        sub = settings.database.find_by_push_token(params[:push_token])
        halt_unknown_push_token! unless sub

        log_push_received(sub)
        return {status: 'deduped'}.to_json if deduped?(sub)

        payload = build_push_payload(sub)
        result = dispatch_push(sub, payload)
        handle_push_result(sub, result)
      end

      helpers do
        # Mastodon は 410 Gone で subscription を自動 destroy するため、
        # 見つからない push_token は stale と見なして 410 で返す（404 だと
        # Mastodon 側に古い subscription が残り続ける）。
        def halt_unknown_push_token!
          # それ自体はエラーではない（stale subscription の自然な掃除）。同一
          # リクエスト内で別の例外が捕捉された際の文脈として breadcrumb を残す
          # に留める (#10 Phase D)。件数そのものの可視化は metrics (#2) 側で扱う。
          Relay::SentrySetup.breadcrumb(
            'Push for unknown token (410)',
            category: 'push',
            data: {push_token: Relay::SentrySetup.mask_token(params[:push_token])},
          )
          halt 410, {error: 'Unknown push token'}.to_json
        end

        # 上流の孤児購読蓄積による重複 push を抑止 (capsicum#692 / #16)。
        # body を読まずに長さを得るため Content-Length を使う（build_push_payload
        # の request.body.read と二重読みにならない）。
        #
        # ⚠ 重複は上流に**配信成功として返す**（4xx/5xx だと retry /
        # subscription destroy を誘発しうるため）。
        def deduped?(sub)
          return false unless settings.push_dedup&.duplicate?(
            params[:push_token],
            topic: request.env['HTTP_TOPIC'],
            length: request.content_length,
          )

          settings.logger.info("Push deduped (#{sub['device_type']}): #{sub['account']}")
          return true
        end
      end
    end
  end
end
