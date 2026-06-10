require 'json'
require 'net/http'
require 'uri'
require_relative 'sentry_setup'

module Relay
  # お知らせ通知 (announcement push) の polling worker。capsicum-relay#14 Phase 2。
  #
  # announcement_subscriptions に登録された server を一定間隔で polling し、
  # 未送信の announcement を seen_announcements で dedup して APNs / FCM に
  # 配信する。取得は各サーバーのモロヘイヤ公開キャッシュ
  # `/mulukhiya/api/announcement/list` 経由（SNS の announcement API は認証
  # 必須なため relay から直接は叩けない）。Mastodon / Misskey 両対応で、
  # normalize_announcement が published_at / createdAt の差分を吸収する。
  # 各サーバーの mulukhiya が features.announcement_push: true (5.24.0+) で有効。
  class AnnouncementWorker
    DEFAULT_INTERVAL = 60
    REQUEST_TIMEOUT = 10

    def initialize(database:, logger:, apns: nil, fcm: nil, interval: DEFAULT_INTERVAL)
      @database = database
      @logger = logger
      @apns = apns
      @fcm = fcm
      @interval = interval
      @stop = false
    end

    def start!
      @thread = Thread.new do
        Thread.current.name = 'announcement_worker'
        run_loop
      end
      @thread.report_on_exception = true
    end

    def stop!
      @stop = true
      @thread&.wakeup if @thread&.alive?
    end

    def poll_once
      @database.announcement_servers.each do |server|
        poll_server(server)
      end
    rescue StandardError => e
      report_error('poll_once', e)
    end

    private

    def run_loop
      until @stop
        begin
          poll_once
        rescue StandardError => e
          report_error('run_loop', e)
        end
        sleep @interval
      end
    end

    def poll_server(server)
      announcements = fetch_announcements(server)
      announcements.each do |announcement|
        id = announcement['id'].to_s
        next if id.empty?
        next if @database.announcement_seen?(server, id)

        dispatch_push(server, announcement)
        @database.mark_announcement_seen(server, id)
      end
    rescue StandardError => e
      report_error("poll_server(#{server})", e)
    end

    # モロヘイヤの公開キャッシュ endpoint (mulukhiya-toot-proxy#4355) を polling。
    # SNS の announcement API は認証必須なため capsicum-relay からは叩けず、モロ
    # ヘイヤが既に info_agent_service で fetch + Redis キャッシュ済みのデータを
    # 経由する。features.announcement_push: true を返す mulukhiya 5.24.0+ で有効。
    # Mastodon / Misskey 両方とも `id` / `content` フィールドを持つため、正規化は
    # published_at (Mastodon) / createdAt (Misskey) の差分吸収だけで済む。
    def fetch_announcements(server)
      uri = URI("https://#{server}/mulukhiya/api/announcement/list")
      response = Net::HTTP.start(uri.hostname, uri.port,
        use_ssl: true,
        open_timeout: REQUEST_TIMEOUT,
        read_timeout: REQUEST_TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      return [] unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      return [] unless parsed.is_a?(Array)
      return parsed.map {|item| normalize_announcement(item)}
    rescue StandardError => e
      @logger.warn(
        "fetch_announcements(#{server}) failed: #{e.class}: #{e.message}",
      )
      return []
    end

    # モロヘイヤ /announcement/list は Mastodon は content + published_at、
    # Misskey は content + createdAt の shape で返す。downstream で扱いやすい
    # 統一 shape に揃える。
    def normalize_announcement(item)
      return {
        'id' => item['id'],
        'content' => item['content'].to_s,
        'published_at' => (item['published_at'] || item['createdAt']).to_s,
      }
    end

    def dispatch_push(server, announcement)
      subs = @database.announcement_subscriptions_for_server(server)
      return if subs.empty?

      payload = build_payload(server, announcement)
      alert = build_alert(announcement)
      subs.each do |sub|
        deliver(sub: sub, payload: payload, alert: alert)
      end
    end

    def deliver(sub:, payload:, alert:)
      enriched = payload.merge('account' => sub['account'])
      case sub['device_type']
      when 'ios'
        return unless @apns

        @apns.push(device_token: sub['token'], payload: enriched, alert: alert)
      when 'android'
        return unless @fcm

        @fcm.push(device_token: sub['token'], payload: enriched)
      end
    rescue StandardError => e
      report_error("deliver(#{sub['device_type']})", e)
    end

    # APNs custom_payload / FCM data は capsicum 側で notification_type を見て
    # NotificationType.announcement に routing される (#477)。FCM の data は
    # transform_values(&:to_s) されるため flat な文字列値で構成する。
    def build_payload(server, announcement)
      {
        'notification_type' => 'announcement',
        'server' => server,
        'announcement_id' => announcement['id'].to_s,
        'announcement_content' => announcement['content'].to_s,
        'announcement_published_at' => announcement['published_at'].to_s,
      }
    end

    def build_alert(announcement)
      {
        title: 'お知らせ',
        body: summarize_content(announcement['content'].to_s),
      }
    end

    # HTML タグを大雑把に剥がしてプレビュー長に切る。詳細表示は capsicum 側で
    # フルレンダリング。
    def summarize_content(html, max: 80)
      plain = html.gsub(/<[^>]+>/, '').gsub(/\s+/, ' ').strip
      return plain.length > max ? "#{plain[0, max]}…" : plain
    end

    def report_error(context, error)
      @logger.error(
        "AnnouncementWorker[#{context}]: #{error.class}: #{error.message}",
      )
      Relay::SentrySetup.capture_exception(
        error, context: {announcement_worker: {context: context}}
      )
    end
  end
end
