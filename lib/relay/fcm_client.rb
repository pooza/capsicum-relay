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

    def initialize(config)
      @config = config
      @project_id = config['fcm']['project_id']
      @authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: File.open(config['fcm']['service_account_path']),
        scope: 'https://www.googleapis.com/auth/firebase.messaging',
      )
    end

    def push(device_token:, payload:)
      uri = URI(FCM_ENDPOINT % @project_id)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{access_token}"
      request['Content-Type'] = 'application/json'
      request.body = {
        message: {
          token: device_token,
          notification: {
            title: 'capsicum',
            body: "#{payload['account']} に通知があります",
          },
          data: payload,
        },
      }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end

      if response.is_a?(Net::HTTPSuccess)
        {success: true, name: JSON.parse(response.body)['name']}
      else
        {
          success: false,
          status: response.code,
          body: response.body,
          permanent: permanent_failure?(response),
        }
      end
    end

    private

    def access_token
      @authorizer.fetch_access_token!
      @authorizer.access_token
    end

    def permanent_failure?(response)
      return true if response.code == '404'

      body = JSON.parse(response.body)
      error_codes = body.dig('error', 'details')&.flat_map {|d| d['errorCode']}&.compact || []
      PERMANENT_ERROR_CODES.any? {|code| error_codes.include?(code)}
    rescue JSON::ParserError
      false
    end
  end
end
