module Relay
  # capsicum 運営元（プリセット）のサーバー (capsicum#597 / #59)。
  #
  # ⚠⚠ **正本は capsicum 側の `packages/capsicum/lib/src/preset_servers.dart`。**
  # ここはその写しで、**2 箇所に同じ一覧がある**。片方だけ増えると
  # 「プリセットなのに非プリセットとして数えられる」形でズレる。
  #
  # ⚠ **クライアントに判定させない。**フェーズ 2 のゲート（#60）は「非プリセット
  # かつ利用権なし」で閉じるので、判定をクライアント側の申告に委ねると
  # **申告を書き換えるだけでゲートを抜けられる**。だから写しを持つ。
  #
  # ⚠⚠ **ズレたときに壊れる向きを覚えておく。**この一覧に載っていないプリセット
  # サーバーの利用者は「非プリセット」として数えられ、**フェーズ 3 でゲートを
  # 閉じたときに止まる。**設計書（`docs/paid-relay-plan.md` 2-4）が
  # 「ゲートを実際に閉じる前に測り直すこと」と書いているのはこのため。
  # ⚠ ズレは気付ける —— 非プリセットとして記録された登録の `server` を見れば、
  # 自分のサーバーが混ざっていることが分かる。
  module PresetServers
    # 本番 + ステージング。⚠ **ステージングも含める**（検証端末でステージングの
    # アカウントを使っているときにゲートが閉じないように・capsicum 側の
    # `kPresetServerHosts` と同じ理由）。
    HOSTS = [
      'mstdn.b-shock.org',
      'precure.ml',
      'mk.precure.fun',
      'mstdn.delmulin.com',
      'misskey.delmulin.com',
      'st2.mstdn.b-shock.org',
      'st3.mstdn.delmulin.com',
      'st2.precure.ml',
      'st2.misskey.delmulin.com',
    ].freeze

    # [server] は `/register` が受け取るホスト名。
    #
    # ⚠ **完全一致で見る。**サブドメインを含めると
    # `evil.mstdn.b-shock.org` のような他人のホストが通る。ステージングは
    # ホストごと [HOSTS] に並べてある。
    #
    # [extra] は設定ファイルの `extra_preset_hosts`。⚠⚠ **足すことしかできない
    # 形にしてある。**置き換えにすると、設定を書き忘れたデプロイで
    # **全登録が非プリセット扱い**になる（フェーズ 3 では全員のゲートが閉じる）。
    def self.preset?(server, extra: nil)
      host = normalize(server)
      return false if host.empty?

      return true if HOSTS.include?(host)
      return Array(extra).map {|entry| normalize(entry)}.include?(host)
    end

    # ⚠ 大小と末尾のドットを揃える。`Mstdn.B-Shock.org` や `mstdn.b-shock.org.`
    # は同じホストで、揃えないと非プリセット扱いになる。
    def self.normalize(server)
      return server.to_s.strip.downcase.delete_suffix('.')
    end
  end
end
