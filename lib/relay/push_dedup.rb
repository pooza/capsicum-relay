require 'monitor'

module Relay
  # 同一通知が短時間に複数回配信される重複を抑止する in-memory dedup
  # (capsicum#692)。
  #
  # 重複の根は上流サーバー（Mastodon/Misskey）に同一エンドポイント宛の
  # Web Push 購読が孤児として蓄積していること。relay 自体は 1:1 フォワーダ
  # なので、同一 push_token へ短時間に連続到着した「同一通知」を 1 回に
  # collapse して端末の重複通知を防ぐ。
  #
  # 設計（保守的 = 取りこぼし最優先回避）:
  # - payload は aes128gcm 暗号化＋メッセージ毎ランダム salt のため、暗号文の
  #   ハッシュでは同一通知を判定できない（relay は復号鍵を持たない）。
  # - 判別材料: `Topic` ヘッダがあれば最優先。無ければ暗号文の Content-Length
  #   （同一平文＋同一鍵なら長さが決定的に一致し、別通知は長さが違いやすい）。
  # - dedup キー = (push_token, basis)。窓は「最初の到着」基準の固定窓で、
  #   重複到着では延長しない。
  # - 判別材料が無い（key が nil）場合は **常に転送**（fail-open）。窓内に来た
  #   別通知を誤って潰すより、重複が稀に漏れる方を許容する。
  #
  # 格納はプロセス内 Hash を Monitor で保護する。config/puma.rb は `workers 0`
  # （単一プロセス＋スレッド）なので全リクエストで共有できる。将来 workers > 0
  # にする場合は共有ストア（SQLite/Redis 等）が要る。
  class PushDedup
    # @param window_ms [Integer] 重複とみなす時間窓（ミリ秒）
    # @param clock [Proc] 単調増加クロック（テスト用に差し替え可能）
    def initialize(window_ms: 1000, clock: nil)
      @window = window_ms / 1000.0
      @clock = clock || -> {Process.clock_gettime(Process::CLOCK_MONOTONIC)}
      @expiry = {} # key => expires_at(monotonic sec)
      @mon = Monitor.new
    end

    # 重複なら true（= dispatch をスキップすべき）。初回 / 窓経過後は false を
    # 返し、その時点から窓を張る。判別材料が無い場合は常に false（fail-open）。
    #
    # @param push_token [String] エンドポイント識別子（同一通知の重複は同一）
    # @param topic [String, nil] `Topic` ヘッダ（あれば最優先の判別材料）
    # @param length [Integer, String, nil] 暗号文の Content-Length（topic 無し時）
    def duplicate?(push_token, topic: nil, length: nil)
      key = dedup_key(push_token, topic, length)
      return false if key.nil?

      now = @clock.call
      @mon.synchronize do
        prune(now)
        existing = @expiry[key]
        if existing && existing > now
          true
        else
          @expiry[key] = now + @window
          false
        end
      end
    end

    private

    # `Topic` ヘッダがあれば最優先、無ければ暗号文の Content-Length を判別材料に
    # する（同一平文＋同一鍵なら長さが決定的に一致し、別通知は長さが違いやすい）。
    # どちらも無ければ nil（fail-open = 必ず転送）。
    def dedup_key(push_token, topic, length)
      if topic && !topic.empty?
        "#{push_token}:t:#{topic}"
      elsif length
        "#{push_token}:l:#{length}"
      end
    end

    # 失効済みエントリを掃除する。push 流量は穏やかなので毎回の全走査で十分
    # （keys 数は同時に窓内に居る購読数程度）。
    def prune(now)
      @expiry.delete_if {|_, expires_at| expires_at <= now}
    end
  end
end
