require_relative 'app'

# ⚠⚠ **停止時に push キューを吐き切る (#55)。**入れないと、再起動でキューに
# 積まれている通知が黙って消える。
#
# ⚠ **ここで呼ぶ。**`configure` の中で `at_exit` を登録すると、`minitest/autorun`
# より後に登録されるぶん**先に走ってしまい、テストが 1 件も動く前にキューが
# 閉じる**（理由は [Relay::BaseApp.install_shutdown_hook!] の doc）。
Relay::App.install_shutdown_hook!

# ⚠⚠ **起動直後の窓を消す (#78)。**冷えたキャッシュのまま push が同時に来ると、
# 枠を取れなかったぶんが `busy`（503）になる。🔴 **Misskey は 5xx を再送しない**
# ので、その通知は消える。
#
# ⚠ **ここで呼ぶ理由は上と同じ** —— `configure` の中でやると、テストが実サーバーへ
# 本当に HTTP を投げる —— `test/support/request_test_case.rb` が `vapid_keys` を
# 差し替えるのは `configure` の**後**なので、間に合わない（2026-09-28 に踏んだ）。
Relay::App.settings.vapid_keys&.warm!

run Relay::App
