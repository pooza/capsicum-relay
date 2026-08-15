require 'json'
require 'time'

module Relay
  # 構造化ログ (#2)。1 行 = 1 JSON オブジェクトで journald に出す。
  #
  # ⚠ **人間向けの 1 行メッセージ (`msg`) を捨てない。** 配信不達の切り分け手順
  # (docs/CLAUDE.md「配信不達の切り分け」) は journald を
  # `grep "Pushed to windows:"` する形で回っており、JSON へ移った瞬間にその手順が
  # 死ぬ。`msg` を同じ文言のまま JSON の中に持たせれば、**grep は今までどおり効き、
  # 加えて jq で集計できる**。移行のコストを運用側に押し付けないための設計。
  #
  # ```console
  # $ journalctl -u capsicum-relay | grep '"event":"push.delivered"' \
  #     | jq -r '[.device_type, .outcome, .latency_ms] | @tsv'
  # ```
  module StructuredLog
    # ::Logger に差す formatter。`logger.info(Hash)` なら中身を展開し、
    # 文字列ならそのまま `msg` に入れる（未計装の呼び出しも JSON になる）。
    FORMATTER = lambda do |severity, time, _progname, message|
      record = {ts: time.utc.iso8601(3), level: severity}
      if message.is_a?(Hash)
        record.merge!(message)
      else
        record[:msg] = message.to_s
      end
      return "#{JSON.generate(compact(record))}\n"
    end

    # nil の項目は落とす。event ごとに出ない項目があるので、そのぶん行が短くなる。
    def self.compact(record)
      return record.compact
    end

    # push_token / device token は**それ自体が capability secret**。ログに全部を
    # 残さない。相関を追うには十分な、先頭 6 文字＋長さの指紋にする。
    # SentrySetup.mask_token と揃えると Sentry 側の値と目視で突き合わせられる。
    def self.fingerprint(token)
      str = token.to_s
      return nil if str.empty?
      return '*' * str.length if str.length <= 12

      return "#{str[0, 6]}…#{str[-4, 4]}"
    end
  end
end
