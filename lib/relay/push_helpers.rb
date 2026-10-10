require 'base64'
require 'json'
require_relative 'sentry_setup'

module Relay
  # App から push 送信・結果ハンドリング系を切り出した Sinatra helper mixin (#27)。
  # App では `helpers Relay::PushHelpers` で混ぜる。Sinatra の helpers はモジュール
  # の mixin なので、`settings` / `request` / `halt` / `status` の request scope は
  # 移動後もそのまま効く。ロジックの書き換えは伴わない、ほぼ純粋な移動。
  module PushHelpers
    # WNS が HTTP 200 でも X-WNS-NotificationStatus に返しうる、received 以外の
    # ステータスのうち **正常系** のもの。dropped は「端末がオフライン / スリープで
    # 受け取れなかった」で、raw notification は queue されないため必ずこうなる。
    # PC を消している時間の方が長い利用者ほど通知量に比例して積み上がり、Sentry へ
    # 上げると本当の異常（channelthrottled・鍵不在・復号失敗）が埋もれる
    # (#24。5.5 週で 4476 件たまった)。journald には残すので、成功ログ
    # (Pushed to windows:) との突き合わせによる切り分けは引き続きできる
    # （手順は docs/CLAUDE.md「配信不達の切り分け」）。
    WNS_BENIGN_STATUSES = ['dropped'].freeze

    def build_push_payload(sub)
      payload = {
        'body' => Base64.strict_encode64(request.body.read),
        'encoding' => request.env['HTTP_CONTENT_ENCODING'].to_s,
        'server' => sub['server'],
        'account' => sub['account'],
      }
      # aes128gcm は body 先頭に salt / sender public key が埋まるので body と
      # encoding で足りるが、レガシー aesgcm は Crypto-Key / Encryption ヘッダに
      # 入るため、存在すれば転送する（旧 Mastodon / 一部 Misskey 対応）。
      crypto_key = request.env['HTTP_CRYPTO_KEY']
      encryption_header = request.env['HTTP_ENCRYPTION']
      payload['crypto_key'] = crypto_key if crypto_key
      payload['encryption'] = encryption_header if encryption_header
      return payload
    end

    # device_type ごとの送信クライアントと表示名を返す。各クライアントは
    # push(device_token:, payload:) を共通 I/F に持つ。未設定なら client は nil。
    def push_client_for(device_type)
      return Relay::PushHelpers.client_for(settings, device_type)
    end

    # ⚠ **module function としても呼べるようにしてある (#55)。**配送ワーカーは
    # request scope の外にいるので helper mixin として混ざっていない。**選択の
    # 規則を 2 箇所に持たない**ための入口。
    def self.client_for(settings, device_type)
      case device_type
      when 'ios', 'macos'
        [apns_for(settings, device_type), 'APNs']
      when 'android'
        [(settings.fcm if settings.respond_to?(:fcm)), 'FCM']
      when 'windows'
        # Windows は WNS raw push。token は Channel URI。relay は暗号文を復号せず
        # payload をそのまま転送し、bg task が復号する (capsicum#474)。
        [(settings.wns if settings.respond_to?(:wns)), 'WNS']
      end
    end

    # iOS / macOS の APNs クライアントを選ぶ。
    #
    # 本番の macOS は iOS と同一 Bundle ID + 同一 APNs Auth Key なので、同じ
    # クライアントに流す (capsicum#468)。⚠ **`apns.macos_bundle_id` を置いた環境
    # だけ、macOS を別のクライアントへ流す** (#95)。宛先が違う端末へ iOS の ID で
    # 送ると APNs は `DeviceTokenNotForTopic` を返し、relay はそれを恒久的な失敗と
    # 読んで**登録ごと消す**（上流へは 410 が返り、購読も消える）。
    def self.apns_for(settings, device_type)
      return settings.apns_macos if device_type == 'macos' && settings.respond_to?(:apns_macos)

      return (settings.apns if settings.respond_to?(:apns))
    end

    # `apns.macos_bundle_id` が、`apns.bundle_id` と違う値で置かれているときだけ返す。
    def self.macos_bundle_id(config)
      value = config.dig('apns', 'macos_bundle_id').to_s.strip
      return nil if value.empty? || value == config.dig('apns', 'bundle_id')

      return value
    end

    def log_push_received(sub)
      log_event(
        'push.received',
        msg: push_received_message(sub),
        device_type: sub['device_type'],
        account: sub['account'],
        server: sub['server'],
        # ⚠ push_token は capability secret。指紋だけ残す。
        push_token: Relay::StructuredLog.fingerprint(sub['push_token']),
        **push_received_fields,
      )
    end

    # 各サーバーがどの暗号化形式で送ってくるかを diagnose できるようにする (#5)。
    # len / topic は dedup (#16) の判別材料の効きを後追いするための観測で、同一
    # 通知の重複バーストが同一 len かつ別通知が別 len になっているかを見てから
    # 窓・キーを調整する。機密情報は含まないため常時出力。
    def push_received_fields
      return {
        encoding: request.env['HTTP_CONTENT_ENCODING'].to_s,
        has_crypto_key: !request.env['HTTP_CRYPTO_KEY'].nil?,
        has_encryption: !request.env['HTTP_ENCRYPTION'].nil?,
        has_topic: !request.env['HTTP_TOPIC'].nil?,
        # Rack は String で返す。jq で数値比較したいので整数に寄せる。
        length: request.content_length&.to_i,
      }
    end

    # 従来と同じ 1 行。docs/CLAUDE.md「配信不達の切り分け」の grep 手順を壊さない。
    def push_received_message(sub)
      fields = push_received_fields
      flags = [
        (fields[:has_crypto_key] ? '+ck' : ''),
        (fields[:has_encryption] ? '+enc' : ''),
      ].join
      topic = fields[:has_topic] ? '+topic' : ''
      return "Received push: #{sub['account']} (#{sub['device_type']}," \
        " encoding=#{fields[:encoding].inspect}#{flags}" \
        " len=#{fields[:length]}#{topic})"
    end
  end
end
