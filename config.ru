require_relative 'app'

# ⚠⚠ **停止時に push キューを吐き切る (#55)。**入れないと、再起動でキューに
# 積まれている通知が黙って消える。
#
# ⚠ **ここで呼ぶ。**`configure` の中で `at_exit` を登録すると、`minitest/autorun`
# より後に登録されるぶん**先に走ってしまい、テストが 1 件も動く前にキューが
# 閉じる**（理由は [Relay::BaseApp.install_shutdown_hook!] の doc）。
Relay::App.install_shutdown_hook!

run Relay::App
