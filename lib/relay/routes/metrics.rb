require_relative '../base_app'

module Relay
  module Routes
    # Prometheus 形式のメトリクス (#2)。
    #
    # ⚠ **認証必須にしている。** 購読数・投げ銭件数は運用上の実数で、公開する
    # 理由が無い。`/health` を無認証にしてあるのは監視から叩くためで、そちらは
    # 「生きているか」しか出さない。
    #
    # ⚠ **counter はプロセス再起動でゼロに戻る**（in-memory）。Prometheus 側は
    # counter reset を扱えるので `rate()` は壊れない。再起動の位置は `/health` の
    # `revision` (#37) と突き合わせられる。
    class Metrics < BaseApp
      get '/metrics' do
        authenticate!

        content_type 'text/plain; version=0.0.4; charset=utf-8'
        settings.metrics.to_prometheus(gauges: gauges)
      end

      helpers do
        # DB から都度読む現在値。counter と違って再起動をまたいで意味を保つ。
        def gauges
          return push_gauges.merge(entitlement_gauges).merge(vapid_gauges)
        end

        # 裏取りの鍵がいくつ手元にあるか (#78)。
        #
        # ⚠⚠ **counter では代わりにならない。**`relay_vapid_verification_total` は
        # **push が来るまで 1 件も出ない**ので、「先読みが効いたか」「TTL が切れて
        # 冷えていないか」を**押し掛けて確かめられない。**
        # ⚠ **冷えていると、同時に来た push が `busy`（503）になる**
        # —— 🔴 Misskey は 5xx を再送しないので通知が消える。
        def vapid_gauges
          cached, total = settings.vapid_keys&.cached_counts || [0, 0]
          return {
            'relay_vapid_keys_cached' => [
              'Preset hosts whose VAPID public key is held (⚠ cold cache makes pushes busy).',
              cached,
            ],
            'relay_vapid_keys_hosts' => ['Preset hosts the relay may fetch keys for.', total],
          }
        end

        def push_gauges
          return {
            'relay_subscriptions' => [
              'Registered device subscriptions.', settings.database.count
            ],
            'relay_announcement_subscriptions' => [
              'Announcement push subscriptions.',
              settings.database.announcement_subscription_count,
            ],
            'relay_supporters' => [
              'Supporters who have tipped at least once.',
              settings.database.supporter_count,
            ],
          }
        end

        # 有償リレー (capsicum#597 / #58)。⚠ **`/health` には出さない。**
        # あちらは無認証で、購入の数は「生きているか」に要らない。
        def entitlement_gauges
          return {
            'relay_entitlements' => [
              'Purchases with an entitlement (⚠ includes unverified ones in phase 1).',
              settings.database.entitlement_count,
            ],
            'relay_entitlement_tokens' => [
              'Devices holding an entitlement token.',
              settings.database.entitlement_token_count,
            ],
          }
        end
      end
    end
  end
end
