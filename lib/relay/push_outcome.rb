require_relative 'push_helpers'

module Relay
  # push クライアントの戻り値 1 つを outcome 文字列に解釈する (#44 / #55)。
  #
  # ⚠ **通常の push 経路とお知らせ配信の両方がここを通る。**#44 の時点では
  # `AnnouncementPushOutcome` という名前で、通常 push 側
  # （`PushHelpers` の `handle_push_result`）は**同じ分岐を別に持っていた** —— 順序と
  # 名前を「コメントで揃える」運用だった。#55 で通常 push の配送を非同期にした
  # ときに、あちらも request scope の外へ出す必要が生じたので、**分岐を 1 本に
  # 畳んで名前も実態に合わせた**。
  #
  # 揃っていると `relay_push_total` と `relay_announcement_push_total` を同じ
  # ラベルで比較でき、「上流からの中継は成功しているのにお知らせ配信だけ落ちて
  # いる」が数字で見える。
  module PushOutcome
    # outcome ごとのログレベル。ここに無いものは :info。
    LEVELS = {
      'degraded' => :warn,
      'oversized' => :warn,
      'failed' => :error,
      'no_result' => :error,
      'exception' => :error,
      'unconfigured' => :warn,
    }.freeze

    # ⚠ 失敗側は **oversized → permanent → failed** の順。入れ替えると、両方立った
    # 結果（上限超過かつ permanent）が gone と呼ばれて**購読を消してしまう**。
    def self.classify(result)
      return 'no_result' unless result.is_a?(Hash)
      return classify_failure(result) unless result[:success]

      wns_status = result[:wns_status]
      return "wns_#{wns_status}" if wns_status && wns_status != 'received'
      return 'degraded' if result[:degraded]

      return 'success'
    end

    def self.classify_failure(result)
      return 'oversized' if result[:oversized]
      return 'gone' if result[:permanent]

      return 'failed'
    end

    # ⚠ **`wns_dropped` は正常系**（端末がオフライン / スリープで raw notification
    # が queue されない）。通常 push 側で 5.5 週に 4476 件たまった実績があり (#24)、
    # warn に上げると本当の異常（channelthrottled・鍵不在）が埋もれる。リストは
    # PushHelpers の定数をそのまま参照する（2 箇所に持たない）。
    def self.level(outcome)
      return :info if benign_wns?(outcome)
      return :warn if outcome.start_with?('wns_')

      return LEVELS.fetch(outcome, :info)
    end

    def self.benign_wns?(outcome)
      return Relay::PushHelpers::WNS_BENIGN_STATUSES.any? do |status|
        outcome == "wns_#{status}"
      end
    end

    # 失敗の材料になる項目だけ拾う。生のレスポンス body は載せない（通常 push 側の
    # [Relay::PushDeliveryReporter] と同じ方針で status / reason に絞る）。
    #
    # ⚠ **成功した回は、配送先が振った識別子を載せる** (#85)。これが無いと
    # 「relay は投げた、端末には出ない」を追う材料が 1 つ足りない —— Apple の
    # Push Notification Console は `apns-id` で配送ログ（受理・端末への配送・
    # 破棄の理由）を引けるが、ログに出ていなければ引く鍵が無い。
    #
    # | キー | 出どころ |
    # | --- | --- |
    # | `apns_id` | APNs の応答ヘッダ `apns-id` |
    # | `fcm_name` | FCM の応答 `name`（`projects/…/messages/…`） |
    # | `wns_msg_id` | WNS の応答ヘッダ `X-WNS-Msg-ID` |
    #
    # ⚠ **通知 1 通の識別子で、個人や端末を名指しする値ではない。**ログ方針
    # （`purchase_id` や token を出さない）には触れない。
    def self.detail(result)
      return {} unless result.is_a?(Hash)

      return {
        status: result[:status],
        reason: result[:reason],
        wns_status: result[:wns_status],
        original_size: result[:original_size],
        apns_id: result[:id],
        fcm_name: result[:name],
        wns_msg_id: result[:msg_id],
      }.compact
    end
  end
end
