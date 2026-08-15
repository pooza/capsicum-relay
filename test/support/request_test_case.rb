require_relative '../test_helper'
require 'fileutils'
require 'json'
require 'sqlite3'
require 'tmpdir'

# ⚠ **app.rb を require する前に env を差し込む。** App の `configure` は
# クラス定義時に走るので、ここで指しておかないと本番の settings.yml / DB を
# 掴もうとする（無ければそのまま落ちる）。これが #34 で「app.rb は
# config/settings.yml 依存で require できない」と書かれていたブロッカーの実体。
ENV['RELAY_CONFIG_PATH'] ||= File.expand_path('../fixtures/settings.yml', __dir__)
unless ENV['RELAY_DB_PATH']
  dir = Dir.mktmpdir('capsicum-relay-request-test')
  # ⚠ **`at_exit` は使えない。** minitest/autorun が先に at_exit を登録して
  # いるので、後から登録したハンドラの方が**先に**走る＝テストが 1 件も動く前に
  # 一時ディレクトリが消える。`Minitest.after_run` はテスト完了後に走る。
  Minitest.after_run {FileUtils.remove_entry(dir)}
  ENV['RELAY_DB_PATH'] = File.join(dir, 'relay.sqlite3')
end

require 'rack/test'
require 'app'

# Sinatra 4 の host authorization は development / test 環境で許可ホストを
# localhost 系に絞る。Rack::Test は `example.org` を名乗るので、そのままだと
# **全リクエストが 403** になる。本番は `RACK_ENV=production` で素通しなので、
# ここだけテスト側で開ける（アプリの設定は変えない）。
Relay::App.set(:host_authorization, {permitted_hosts: []})

# route は登録・配信のたびに info ログを吐く。テスト出力に混ぜても読めないので
# 捨てる（ログの内容そのものを検証するケースは今のところ無い）。
Relay::App.set(:logger, Logger.new(File::NULL))

# route の request テストの土台 (#34)。
#
# 単一の App インスタンスと 1 つの一時 DB を全ケースで共有するので、
# **setup で毎回テーブルを空にする**（順序依存のテストを書けなくする）。
class RequestTestCase < Minitest::Test
  include Rack::Test::Methods

  SECRET = 'test-secret'.freeze

  TABLES = ['announcement_subscriptions', 'supporters', 'subscriptions'].freeze

  def app
    return Relay::App
  end

  def database
    return Relay::App.settings.database
  end

  def setup
    db = SQLite3::Database.new(ENV.fetch('RELAY_DB_PATH'))
    # 子から先に消す（subscriptions を先に消すと FK ON DELETE CASCADE 頼みに
    # なり、意図せず「消えたこと」を検証してしまう）。
    TABLES.each {|table| db.execute("DELETE FROM #{table}")}
    db.close
  end

  # 認証つきの JSON POST / DELETE / GET。ヘッダ名を各ケースで書かない。
  def auth_headers(secret: SECRET)
    return {'HTTP_X_RELAY_SECRET' => secret, 'CONTENT_TYPE' => 'application/json'}
  end

  def post_json(path, body, secret: SECRET)
    return post(path, body.is_a?(String) ? body : body.to_json, auth_headers(secret: secret))
  end

  def json_response
    return JSON.parse(last_response.body)
  end

  # 親 subscription を 1 件作り、その push_token を返す。
  # announcement_subscriptions は FK でこれが要る。
  def register_subscription(
    token: 'device-token', device_type: 'ios',
    account: 'alice@example.test', server: 'example.test'
  )
    post_json(
      '/register',
      {token: token, device_type: device_type, account: account, server: server},
    )
    return JSON.parse(last_response.body)
  end
end
