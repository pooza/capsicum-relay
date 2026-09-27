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

    def push(device_token:, payload:)
      uri = URI(FCM_ENDPOINT % @project_id)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(build_request(uri, device_token, payload))
      end
      if response.is_a?(Net::HTTPSuccess)
        return {success: true, name: JSON.parse(response.body)['name']}
      end
      return {
        success: false,
        status: response.code,
        body: response.body,
        permanent: permanent_failure?(response),
        oversized: oversized_payload?(response),
      }
    end

    private

    def build_request(uri, device_token, payload)
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
          data: payload.transform_values(&:to_s),
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
