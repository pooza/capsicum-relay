require 'monitor'

module Relay
  # SQLite の接続を 1 本のまま、スレッド間で 1 呼び出しずつ直列にする (Codex P2・PR #75)。
  #
  # ⚠⚠ **接続は puma のスレッド間で共有**（`workers 0` / `threads 2`）で、SQLite の
  # トランザクションは**接続単位**。鍵が無いと:
  #
  # - 2 本が同時に `BEGIN` すると入れ子で落ち、後始末で先の 1 本まで巻き戻す
  # - トランザクションの途中に**別のリクエストの SQL が混ざり**、未確定の状態を読んだり、
  #   巻き戻しに巻き込まれたりする
  #
  # ⚠ **再入できる鍵（Monitor）にする。**`transaction` のブロックの中から同じスレッドが
  # `execute` を呼ぶので、Mutex だと自分で自分を待って止まる。**トランザクションの間は
  # 鍵を持ち続ける**ので、ほかのスレッドの SQL はブロックが抜けるまで待つ。
  class SerializedConnection
    def initialize(connection)
      @connection = connection
      @lock = Monitor.new
    end

    def method_missing(name, ...)
      return super unless @connection.respond_to?(name)

      return @lock.synchronize {@connection.public_send(name, ...)}
    end

    def respond_to_missing?(name, include_private = false)
      return @connection.respond_to?(name, include_private) || super
    end
  end
end
