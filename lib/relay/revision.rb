module Relay
  # 稼働中のコードを名乗る commit SHA (#37)。
  #
  # relay は **main への merge がそのまま本番の単位**で、capsicum のリリースとは
  # 独立に進む（マイルストーン名だけ揃えている）。したがって「1.57.0」のような
  # 版を名乗らせても実際に動いているコードと 1 対 1 で対応しないため、名乗るのは
  # SHA にする。
  #
  # ⚠ **Sentry の release と `/health` の revision は同じ文字列**にする。変換なしで
  # 突き合わせられることがこの値の主用途（「本番が古いままでは？」を SSH せずに
  # 排除する / Sentry の release 別グラフと突き合わせる）。取得ロジックがここに 1 本
  # しかないのはそのため。
  module Revision
    # デプロイ時に固定したい場合の env。git チェックアウトを持たない配置
    # （アーカイブ展開等）でもここを設定すれば名乗れる。
    ENV_KEY = 'SENTRY_RELEASE'.freeze

    # 解決済みの SHA。取得できなければ nil。
    #
    # プロセスが生きている間 revision は変わらない（デプロイは再起動を伴う）ので
    # 1 度だけ解決して覚える。`/health` は監視から定期的に叩かれるため、毎回
    # `git rev-parse` を fork すると素直に無駄。
    def self.current
      return @current if defined?(@current)

      @current = resolve
    end

    # テストからメモ化を捨てるための入口。
    def self.reset!
      remove_instance_variable(:@current) if defined?(@current)
    end

    # env 優先 → git フォールバックの順。[head] はテスト用の注入点で、
    # 省略時は実際に `git rev-parse HEAD` を叩く。
    def self.resolve(env: ENV, head: nil)
      explicit = env[ENV_KEY].to_s.strip
      return explicit unless explicit.empty?

      sha = (head || git_head).to_s.strip
      return sha.empty? ? nil : sha
    end

    # git チェックアウト外・git 未導入でも落ちない。名乗れないことは異常では
    # ないので、nil を返して呼び出し側に判断を委ねる。
    def self.git_head
      return `git rev-parse HEAD 2>/dev/null`.strip
    rescue StandardError
      return nil
    end
  end
end
