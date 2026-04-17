workers 0
threads_count = Integer(ENV.fetch('PUMA_THREADS', 2))
threads threads_count, threads_count

bind 'tcp://127.0.0.1:9292'

environment ENV.fetch('RACK_ENV', 'development')

pidfile 'tmp/puma.pid'
