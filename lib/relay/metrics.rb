require 'monitor'

module Relay
  # プロセス内カウンタと Prometheus 形式の露出 (#2)。
  #
  # 構造化ログ (#2 の本体) があれば journald + jq で後追い集計はできるが、
  # **「今どうなっているか」を一発で見る母数**が要る場面がある — 配信不達の
  # 切り分けで最初に見るのは「そもそも relay に届いているか / 送れているか」で、
  # そこを 14 日ぶんの journald 走査から始めるのは重い。
  #
  # 格納はプロセス内 Hash を Monitor で保護する。config/puma.rb は `workers 0`
  # （単一プロセス＋スレッド）なので全リクエストで共有できる。⚠ PushDedup と
  # **同じ前提に乗っている**ので、workers > 0 にするなら両方まとめて共有ストアへ
  # 移す必要がある。
  #
  # ⚠ **プロセス再起動でゼロに戻る。** Prometheus の counter は単調増加を前提に
  # `rate()` を取るので、再起動をまたぐ差分は scraper 側が扱う（`revision` が
  # 変わるので再起動の位置は #37 の値で分かる）。
  class Metrics
    # 出す counter の定義。`# HELP` / `# TYPE` を書くために名前と説明を持つ。
    COUNTERS = {
      'relay_push_total' => 'Web Push received from upstream, by device_type and outcome.',
      'relay_register_total' => 'Device registration changes, by action.',
      'relay_announcement_subscription_total' =>
        'Announcement subscription changes, by action.',
      'relay_supporter_tip_total' => 'Supporter tips recorded.',
    }.freeze

    def initialize
      @counters = Hash.new(0)
      @mon = Monitor.new
    end

    # [labels] はラベル名 => 値。値は Prometheus のラベル値として出す。
    def increment(name, labels = {}, by: 1)
      @mon.synchronize {@counters[[name, normalize(labels)]] += by}
    end

    def value(name, labels = {})
      return @mon.synchronize {@counters[[name, normalize(labels)]]}
    end

    def reset!
      @mon.synchronize {@counters.clear}
    end

    # Prometheus text exposition format。[gauges] は名前 => [説明, 値] で、
    # DB から都度読む現在値（購読数など）を渡す。
    def to_prometheus(gauges: {})
      lines = []
      COUNTERS.each do |name, help|
        lines.concat(counter_lines(name, help))
      end
      gauges.each do |name, (help, value)|
        lines << "# HELP #{name} #{help}"
        lines << "# TYPE #{name} gauge"
        lines << "#{name} #{value}"
      end
      return "#{lines.join("\n")}\n"
    end

    private

    # ⚠ **値が 0 でも系列を出す。** 一度も起きていない outcome の系列が消えると、
    # Prometheus 側で「まだ起きていない」と「scrape できていない」が区別できない。
    # ただし出せるのは実際に観測したラベルの組み合わせだけなので、起動直後は
    # 系列そのものが無い（counter の名前と HELP は必ず出す）。
    def counter_lines(name, help)
      lines = ["# HELP #{name} #{help}", "# TYPE #{name} counter"]
      snapshot(name).each do |labels, value|
        lines << "#{name}#{render_labels(labels)} #{value}"
      end
      return lines
    end

    def snapshot(name)
      return @mon.synchronize do
        @counters.select {|(counter, _), _| counter == name}
            .to_h {|(_, labels), value| [labels, value]}
      end
    end

    def normalize(labels)
      return labels.to_h {|key, value| [key.to_s, value.to_s]}.sort.to_h
    end

    def render_labels(labels)
      return '' if labels.empty?

      body = labels.map {|key, value| %(#{key}="#{escape(value)}")}.join(',')
      return "{#{body}}"
    end

    # Prometheus のラベル値でエスケープが要るのは `\` / `"` / 改行の 3 つ。
    def escape(value)
      return value.gsub('\\', '\\\\\\\\').gsub('"', '\"').gsub("\n", '\n')
    end
  end
end
