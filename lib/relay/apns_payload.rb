require 'apnotic'

module Relay
  # APNs へ送る Notification の組み立てと、payload 上限に対する degrade 判断 (#17)。
  #
  # ApnsClient から分けているのは、この責務が **接続・再送・応答解釈を一切知らずに
  # 済む**ため（bundle_id と payload だけで完結する）。WnsClient のように inline
  # disable で ClassLength を伸ばすより、素直な seam で切った方が単体で検証できる。
  #
  # degrade の意味: APNs は payload 上限超過を 413 PayloadTooLarge で返し、その 1 通は
  # 端末に一切届かない（#9 で drop 扱いにした）。暗号化 body を落とせば aps.alert の
  # 汎用文面だけは届けられるので、上限超過時はそこへ倒す。iOS / macOS の NSE も Dart
  # 側 dispatcher も body / encoding 不在を「復号せず relay の alert をそのまま出す」
  # 経路として既に持っており（お知らせ通知 capsicum#477 が同じ形で出荷済み）、client
  # 側の変更なしでこの degrade に乗る。
  class ApnsPayload
    # APNs alert push の payload 上限 (バイト)。aps と custom_payload を JSON 化した
    # 全体に効くので、判定は組み立て済み Notification#body のバイト数で行う。
    PAYLOAD_LIMIT = 4096
    # degrade で落とす、暗号化 Web Push 由来のキー (push_helpers の build_push_payload)。
    # body が実質すべての容量を占めるが、body 抜きでは意味を持たない同伴キーも一緒に
    # 落として「復号を試みない payload」として辻褄を合わせる。
    ENCRYPTED_KEYS = ['body', 'encoding', 'crypto_key', 'encryption'].freeze

    # build の戻り値。
    #   notification  : 送るべき Notification。degrade しても上限を割れないときだけ nil
    #   degraded_from : degrade したときの「degrade 前」バイト数。していなければ nil
    #   byte_size     : 実際に送る（送れないときは degrade 後の）バイト数
    Built = Struct.new(:notification, :degraded_from, :byte_size, keyword_init: true)

    def initialize(bundle_id)
      @bundle_id = bundle_id
    end

    def build(device_token:, payload:, alert: nil)
      notification = build_notification(device_token, payload, alert)
      size = notification.body.bytesize
      return Built.new(notification: notification, byte_size: size) if size <= PAYLOAD_LIMIT

      fallback = build_notification(device_token, degraded_payload(payload), alert)
      fallback_size = fallback.body.bytesize
      return Built.new(byte_size: fallback_size) if fallback_size > PAYLOAD_LIMIT

      return Built.new(notification: fallback, degraded_from: size, byte_size: fallback_size)
    end

    private

    def degraded_payload(payload)
      return payload.reject {|key, _| ENCRYPTED_KEYS.include?(key.to_s)}
    end

    def build_notification(device_token, payload, alert)
      notification = Apnotic::Notification.new(device_token)
      notification.topic = @bundle_id
      notification.alert = alert || {
        title: 'capsicum',
        body: "#{payload['account']} に通知があります",
      }
      notification.sound = 'default'
      notification.mutable_content = true
      notification.custom_payload = payload
      notification.push_type = 'alert'
      return notification
    end
  end
end
