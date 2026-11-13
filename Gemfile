source 'https://rubygems.org'

ruby '~> 4.0.5'

# Web framework
gem 'puma'
gem 'sinatra'

# JSON
gem 'json'

# Database
gem 'sqlite3'

# APNs (HTTP/2)
gem 'apnotic'

# FCM v1 API
gem 'googleauth'

# Web Push decryption (aesgcm / aes128gcm)
gem 'openssl'

# HTTP client (FCM)
gem 'net-http'

# Logging
gem 'logger'

# YAML config
gem 'yaml'

# エラーアラート (capsicum-relay#10)
gem 'sentry-ruby'

group :development do
  # ⚠⚠ main を追わず SHA で固定する（pooza/ginseng-style#75・README「SHA で固定する」）。
  # main を追うと lock の revision が手で上げるまで進まず、2026-11-13 に約 3 か月
  # 取り残されていた（#113）。上げるときは ginseng-style のタグの SHA に書き換える。
  gem 'ginseng-style', github: 'pooza/ginseng-style',
    ref: '127c2854e76811eeec41e21c7bf262b4a527d2b7', require: false # v1.1.15
  # テスト (#25 / #26)。Ruby 4.0 では bundled gem も Gemfile に書かないと
  # bundle 配下で require できないため明示する。本番は
  # BUNDLE_WITHOUT=development なので本番には入らない。
  gem 'minitest'
  gem 'rake'
  # route の request テスト (#34)。app.rb を Rack app として直接叩く。
  gem 'rack-test'
end
