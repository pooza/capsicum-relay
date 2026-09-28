require_relative 'app'

# ⚠⚠ **停止時に push キューを吐き切る (#55)。**入れないと、再起動でキューに
# 積まれている通知が黙って消える。
#
# ⚠ **ここで呼ぶ。**`configure` の中で `at_exit` を登録すると、`minitest/autorun`
# より後に登録されるぶん**先に走ってしまい、テストが 1 件も動く前にキューが
# 閉じる**（理由は [Relay::BaseApp.install_shutdown_hook!] の doc）。
Relay::App.install_shutdown_hook!

# ⚠⚠ **受け付ける前にプリセットの鍵を温めておく (#78)。**冷えたまま push が
# 同時に来ると、枠を取れなかったぶんが `busy`（503）になる。🔴 **Misskey は
# 5xx を再送しない**ので、その通知は消える。
#
# ⚠ **`run` の前に置く。**背景へ投げっぱなしにすると、温めている最中の push が
# `busy` になる（PR #79 の Codex P1）。⚠ **実測 488ms** なので待ってよい。
# ⚠⚠ 上限つきで待つ理由は [Relay::VapidKeyDirectory::WARM_BUDGET] の doc。
#
# ⚠ **`configure` の中でやらない** —— テストが実サーバーへ本当に HTTP を投げる
# （`test/support/request_test_case.rb` の差し替えは `configure` の**後**）。
Relay::App.settings.vapid_keys&.warm!

run Relay::App
