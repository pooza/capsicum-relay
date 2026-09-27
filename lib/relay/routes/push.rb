require_relative '../base_app'
require_relative '../sentry_setup'
require_relative '../structured_log'

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
        # 有償リレーの認可 (capsicum#597 / #60)。⚠⚠ **既定では何も閉じない。**
        #
        # ⚠⚠ **止めるのは `/push`。**Web Push の購読は fedi サーバー側が持っている
        # ので、`/register` を拒んでも**既存の購読は生き続けてここを叩き続ける**。
        # ⚠ **`410 Gone` を返す**と Mastodon / Misskey が購読を掃除するので、
        # サーバー側にゴミを残さず無駄な配送も止まる。黙って 200 を返すと
        # **失効後も永久に叩かれる。**
        halt_entitlement_gone! unless entitlement_allowed?(sub, route: 'push')
        return {status: 'deduped'}.to_json if deduped?(sub)

        # ⚠⚠ **クライアント未設定は同期で 503。**キューに積んでから「未設定でした」と
        # 分かる形にすると、設定漏れが 202 に隠れて**気付けなくなる**。
        ensure_push_client!(sub)
        # ⚠ **payload はここで組む。**`request.body` はリクエストの中でしか読めない。
        accept_push(sub, build_push_payload(sub))
      end

      helpers do
        # Mastodon は 410 Gone で subscription を自動 destroy するため、
        # 見つからない push_token は stale と見なして 410 で返す（404 だと
        # Mastodon 側に古い subscription が残り続ける）。
        def halt_unknown_push_token!
          # それ自体はエラーではない（stale subscription の自然な掃除）。同一
          # リクエスト内で別の例外が捕捉された際の文脈として breadcrumb を残す
          # に留める (#10 Phase D)。
          Relay::SentrySetup.breadcrumb(
            'Push for unknown token (410)',
            category: 'push',
            data: {push_token: Relay::SentrySetup.mask_token(params[:push_token])},
          )
          # ⚠⚠ **記録を残す (#60)。**以前はログも metric も無く、**relay 側から
          # 「410 を返した」ことが一切見えなかった** —— #60 の検証で
          # 「fedi サーバー側の購読が消えるか」を確かめたとき、**nginx の
          # アクセスログを読むしか手が無かった**。410 は上流の購読を消す副作用が
          # あるので、**返した回数は観測できないといけない。**
          metrics.increment('relay_push_stale_token_total')
          log_event(
            'push.stale_token',
            msg: 'Push for unknown token (410)',
            # ⚠ push_token は capability secret。指紋だけ残す。
            push_token: Relay::StructuredLog.fingerprint(params[:push_token]),
            latency_ms: latency_ms,
          )
          halt 410, {error: 'Unknown push token'}.to_json
        end

        # 配送はワーカーへ渡し、受信は即返す (#55)。⚠⚠ **遅い 1 通が puma の
        # スレッドを占有していたのをやめる**のが眼目（Windows は 1 通 2,056ms で、
        # 2 通並ぶと約 2 秒は他の push を受け付けられなかった）。設計は
        # [Relay::PushQueue] の doc が正本。
        #
        # ⚠ **満杯なら 503。**黙って捨てると失われたことが誰にも分からない。
        # ⚠ **4xx にしてはいけない**（Mastodon が購読を消す・#66）。
        def accept_push(sub, payload)
          queue = settings.push_queue
          accepted = queue.enqueue(
            subscription: sub, payload: payload, request_id: request_id,
          )
          unless accepted
            push_reporter.record_rejected(
              sub: sub, depth: queue.depth, request_id: request_id,
            )
            halt 503, {error: 'Push queue full'}.to_json
          end
          # ⚠ **202 Accepted。**200 ではない —— 「配送したか」はまだ分からない。
          status 202
          return {status: 'accepted', queued: queue.depth}.to_json
        end

        # ⚠ 観測だけのために reporter を借りる（配送はワーカーが持っている）。
        def push_reporter
          return settings.push_queue.reporter
        end

        def ensure_push_client!(sub)
          client, name = push_client_for(sub['device_type'])
          halt 503, {error: "#{name} not configured"}.to_json unless client
        end

        # 利用権が無いので購読ごと掃除させる (capsicum#597 / #60)。
        #
        # ⚠ **`subscriptions` の行は消さない。**購入が復活したときにクライアントが
        # 再登録すれば `push_token` を保ったまま同じ行が使われる（消すと
        # `push_token` が変わり、`announcement_subscriptions` も CASCADE で消える）。
        # ⚠ 復帰には**再登録が要る**（設計書 未決事項 4・capsicum#1123 の導線）。
        def halt_entitlement_gone!
          halt 410, {error: 'Entitlement required'}.to_json
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

          push_reporter.record_deduped(
            sub: sub, request_id: request_id, latency_ms: latency_ms,
          )
          return true
        end
      end
    end
  end
end
