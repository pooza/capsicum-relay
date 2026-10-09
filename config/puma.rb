workers 0
# ⚠ **`Relay::StoreVerification.foreground_limit` も同じ `PUMA_THREADS` を読んでいる**
# (#93)。前景でストアへ問い合わせてよい本数を「スレッド数 - 1」で決めているので、
# ここの読み方（環境変数の名前・既定値）を変えるなら、あちらも一緒に変えること。
# 黙ってずれると、検証が全スレッドを握って通知の受信が止まる。
threads_count = Integer(ENV.fetch('PUMA_THREADS', 2))
threads threads_count, threads_count

bind 'tcp://127.0.0.1:9292'

environment ENV.fetch('RACK_ENV', 'development')

pidfile 'tmp/puma.pid'
