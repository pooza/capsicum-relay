require 'rack/mock'
require_relative 'support/request_test_case'

# `POST /push/*` の本文をフォームとして読ませない (#118)。
#
# ⚠ **ほかのテストは常に `application/octet-stream` を付けて投げていた**ので、
# Akkoma のように Content-Type を付けてこない上流が 400 で捨てられていたのを
# 見ていなかった。ここでは「付けてこない」「フォーム形式」を明示して投げる。
class PushContentTypeTest < RequestTestCase
  # 本文は暗号文。`%` を含むバイナリは、フォームとして読むと壊れた値になる。
  BINARY_BODY = "\x8f%zz\x00\xff%\xe3\x81=&a=%".b.freeze

  def setup
    super
    @parent = register_subscription
  end

  def push_with(content_type)
    env = {}
    env['CONTENT_TYPE'] = content_type unless content_type.nil?
    return post("/push/#{@parent['push_token']}", BINARY_BODY, env)
  end

  ## route まで届く（400 にならない）

  # fixture は配送クライアントを持たないので、route に入れば 503 で止まる。
  # ⚠ 修正前はどれも 400（route に入る前に Sinatra が断っていた）。
  def test_missing_content_type_reaches_the_route
    push_with(nil)

    assert_equal(503, last_response.status)
  end

  def test_form_content_type_reaches_the_route
    push_with('application/x-www-form-urlencoded')

    assert_equal(503, last_response.status)
  end

  def test_form_content_type_with_charset_reaches_the_route
    push_with('application/x-www-form-urlencoded; charset=utf-8')

    assert_equal(503, last_response.status)
  end

  def test_octet_stream_still_reaches_the_route
    push_with('application/octet-stream')

    assert_equal(503, last_response.status)
  end

  ## middleware の単体: 本文と Content-Type

  def downstream_seen(path:, content_type:, method: 'POST')
    seen = {}
    inner = lambda do |env|
      request = Rack::Request.new(env)
      seen[:content_type] = env['CONTENT_TYPE']
      seen[:original] = env[Relay::PushContentType::ORIGINAL_KEY]
      seen[:form] = request.form_data?
      seen[:body] = request.body.read
      [200, {}, []]
    end
    opts = {method: method, input: BINARY_BODY}
    opts['CONTENT_TYPE'] = content_type unless content_type.nil?
    Relay::PushContentType.new(inner).call(Rack::MockRequest.env_for(path, opts))
    return seen
  end

  def test_push_body_is_passed_through_unchanged_as_binary
    seen = downstream_seen(path: '/push/abc', content_type: 'application/x-www-form-urlencoded')

    assert_equal('application/octet-stream', seen[:content_type])
    refute(seen[:form])
    assert_equal(BINARY_BODY, seen[:body].b)
    assert_equal('application/x-www-form-urlencoded', seen[:original])
  end

  def test_missing_content_type_is_recorded_as_empty
    seen = downstream_seen(path: '/push/abc', content_type: nil)

    assert_equal('application/octet-stream', seen[:content_type])
    assert_equal('', seen[:original])
  end

  # Mastodon の送り方は触らない。
  def test_octet_stream_is_left_as_is
    seen = downstream_seen(path: '/push/abc', content_type: 'application/octet-stream')

    assert_equal('application/octet-stream', seen[:content_type])
    assert_equal('application/octet-stream', seen[:original])
  end

  # ⚠ **/push 以外は読み替えない**（JSON / フォームを受ける route がある）。
  def test_other_paths_are_not_rewritten
    seen = downstream_seen(path: '/register', content_type: 'application/x-www-form-urlencoded')

    assert_equal('application/x-www-form-urlencoded', seen[:content_type])
    assert_nil(seen[:original])
  end

  # `/pushx` のように接頭辞だけ同じパスは対象外。
  def test_path_must_be_under_push_directory
    seen = downstream_seen(path: '/pushx/abc', content_type: 'application/x-www-form-urlencoded')

    assert_equal('application/x-www-form-urlencoded', seen[:content_type])
  end

  def test_get_is_not_rewritten
    seen = downstream_seen(path: '/push/abc', content_type: nil, method: 'GET')

    assert_nil(seen[:original])
  end

  ## 構成: Relay::App の先頭にある

  # ⚠ route のクラスはどれも自分の `call` で `params` を組み立てるので、
  # 1 本目より後ろに置くとそこで先に 400 になる。
  def test_middleware_is_ahead_of_every_route
    klasses = Relay::App.middleware.map(&:first)
    index = klasses.index(Relay::PushContentType)

    refute_nil(index)
    route_indexes = klasses.each_index.select {|i| klasses[i].name.to_s.start_with?('Relay::Routes::')}

    refute_empty(route_indexes)
    assert_operator(index, :<, route_indexes.min)
  end
end
