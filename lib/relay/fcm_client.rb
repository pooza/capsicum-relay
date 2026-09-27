require 'googleauth'
require 'net/http'
require 'json'
require 'uri'

module Relay
  class FcmClient
    FCM_ENDPOINT = 'https://fcm.googleapis.com/v1/projects/%s/messages:send'.freeze

    # FCM が返す errorCode のうち「デバイストークン自体が無効」を示すもの。
    # INVALID_ARGUMENT は request 側のバグでも返るため含めない（誤削除回避）。
    PERMANENT_ERROR_CODES = ['UNREGISTERED', 'SENDER_ID_MISMATCH'].freeze

    # ⚠⚠ **文言は FCM 側で変わる。**#9 の時点の "Android message is too big" を
    # 小文字 1 本で探していたが、2026-09 の本番では
    # "Message is too large. The maximum is 4K (4096 bytes)." が返っており、
    # **一度も当たらず `failed` に落ちていた**（#71）。大文字小文字を問わず、
    # 新旧どちらの言い回しも拾う。
    OVERSIZED_MESSAGE = /too (?:big|large)/i

    # FCM data message の上限 (#71)。⚠ FCM の数え方（キーと値のバイト数）より
    # **data を JSON にしたバイト数のほうが必ず大きい**ので、それで測れば取りこぼさない
    # （上限すれすれの通知を 1 通余計に degrade するだけ）。
    PAYLOAD_LIMIT = 4096
    # degrade で落とす暗号化 Web Push 由来のキー。
    # [Relay::ApnsPayload::ENCRYPTED_KEYS] と同じ集合（テストで一致を固定している）。
    ENCRYPTED_KEYS = ['body', 'encoding', 'crypto_key', 'encryption'].freeze
    # degrade しても上限を割れず、送る前に倒したときの合成 status / reason。
    # APNs / WNS の pre-check と同じく oversized（購読を残して 1 通だけ落とす）に倒す。
    OVERSIZED_STATUS = '413'.freeze
    OVERSIZED_PRECHECK_REASON = 'PayloadTooLarge (pre-check)'.freeze

    def initialize(config)
      @config = config
      @project_id = config['fcm']['project_id']
      @authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: File.open(config['fcm']['service_account_path']),
        scope: 'https://www.googleapis.com/auth/firebase.messaging',
      )
    end

    # 認証情報なしで検査できるよう、応答コードと本文だけで判定する。
    def self.oversized_response?(code, body)
      return false unless code.to_s == '400'

      message = JSON.parse(body.to_s).dig('error', 'message').to_s
      return OVERSIZED_MESSAGE.match?(message)
    rescue JSON::ParserError
      return false
    end

    # 送る data と、degrade したときの「degrade 前」バイト数を返す (#71)。
    #
    # ⚠ **4KB を超えたら暗号化 body を落として汎用文面へ倒す。**capsicum の Android
    # 受信側（`PushMessageDispatcher.dispatch`）は body / encoding が無いと復号を
    # 飛ばして「{account} に通知があります」を出すので、**アプリ側の変更なしで届く**。
    # APNs (#17) / WNS (#65) と同じ倒し方。degrade しても割れないときは data を nil で返す。
    def self.build_data(payload)
      data = payload.transform_values(&:to_s)
      size = data.to_json.bytesize
      return [data, nil] if size <= PAYLOAD_LIMIT

      fallback = data.reject {|key, _| ENCRYPTED_KEYS.include?(key.to_s)}
      return [nil, size] if fallback.to_json.bytesize > PAYLOAD_LIMIT

      return [fallback, size]
    end

    def push(device_token:, payload:)
      data, degraded_from = self.class.build_data(payload)
      return oversized_precheck_result unless data

      uri = URI(FCM_ENDPOINT % @project_id)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(build_request(uri, device_token, data))
      end
      return delivered(response, degraded_from) if response.is_a?(Net::HTTPSuccess)

      return {
        success: false,
        status: response.code,
        body: response.body,
        permanent: permanent_failure?(response),
        oversized: oversized_payload?(response),
      }
    end

    private

    # degrade して送ったときだけ degraded / original_size を添える。上位
    # （`PushOutcome` の `degraded`）が「届いたが本文は読めない」を観測するのに使う。
    def delivered(response, degraded_from)
      result = {success: true, name: JSON.parse(response.body)['name']}
      return result unless degraded_from

      return result.merge(degraded: true, original_size: degraded_from)
    end

    def oversized_precheck_result
      return {
        success: false,
        status: OVERSIZED_STATUS,
        reason: OVERSIZED_PRECHECK_REASON,
        permanent: false,
        oversized: true,
      }
    end

    def build_request(uri, device_token, data)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{access_token}"
      request['Content-Type'] = 'application/json'
      # data-only メッセージ。capsicum 側で RFC 8291 復号して通知内容を個別化
      # するため notification フィールドは付けない（付けると OS がバックグラウンド
      # 時に通知ブロックを直接描画してしまい、アプリ側の復号ハンドラが発火
      # する前に「${account} に通知があります」が出る）。
      # Android は data-only で priority 未指定だと遅延配信になりうるので
      # HIGH を明示する。
      request.body = {
        message: {
          token: device_token,
          data: data,
          android: {
            priority: 'HIGH',
          },
        },
      }.to_json
      return request
    end

    def access_token
      @authorizer.fetch_access_token!
      return @authorizer.access_token
    end

    def permanent_failure?(response)
      return true if response.code == '404'

      body = JSON.parse(response.body)
      error_codes = body.dig('error', 'details')&.flat_map {|d| d['errorCode']}&.compact || []
      return PERMANENT_ERROR_CODES.any? {|code| error_codes.include?(code)}
    rescue JSON::ParserError
      return false
    end

    # FCM data message は 4KB 制限。超過すると INVALID_ARGUMENT 400 が返るが、
    # INVALID_ARGUMENT 全体を permanent にすると request 側のバグまで unregister
    # してしまうため、メッセージ文字列で限定マッチして oversized フラグを立てる
    # (#9)。oversized は subscription を残したまま該当通知だけドロップする。
    def oversized_payload?(response)
      return self.class.oversized_response?(response.code, response.body)
    end
  end
end
