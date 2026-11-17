module Relay
  # `POST /push/*` の本文を、フォームとして読ませないための Rack middleware (#118)。
  #
  # 🔴 **Akkoma からの Web Push が、route に入る前に 400 で捨てられていた。**
  # Sinatra は route を探す前に `params` を組み立て、そのとき `Content-Type` が
  # **無い**か**フォーム形式**だと本文をフォームとして読む。本文は暗号文（バイナリ）
  # なので壊れた値になり、Sinatra は 400 を返す。⚠ **アプリのログには何も残らない**
  # （`push.received` にも `push.stale_token` にも出ない）うえ、上流は 400 を受けて
  # 購読を消す。Mastodon は `application/octet-stream` を付けて送るので、これまで
  # 表に出なかった（テストも常にそれを付けていた）。
  #
  # ⚠ **`/push` に限る。**ほかの route は JSON を受けるので、読み替えると壊れる。
  # `/push` の本文は RFC 8030 / 8291 の暗号文で、フォームとして読む理由が無い。
  #
  # ⚠ **`Relay::App` の先頭に置く。**route のクラスは middleware として連なって
  # いて、**どのクラスも自分の `call` で `params` を組み立てる**（route が一致
  # しなくても）。1 本目より後ろに置くと、そこで先に 400 になる。
  class PushContentType
    PATH_PREFIX = '/push/'.freeze
    BINARY = 'application/octet-stream'.freeze
    FORM_TYPES = ['application/x-www-form-urlencoded', 'multipart/form-data'].freeze
    # 読み替える前の値。`push.received` に `content_type` として出す（上流ごとの
    # 送り方を後から確かめられるように）。
    ORIGINAL_KEY = 'relay.push.original_content_type'.freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      rewrite!(env) if push_request?(env)
      return @app.call(env)
    end

    private

    def push_request?(env)
      return env['REQUEST_METHOD'] == 'POST' && env['PATH_INFO'].to_s.start_with?(PATH_PREFIX)
    end

    def rewrite!(env)
      original = env['CONTENT_TYPE'].to_s
      env[ORIGINAL_KEY] = original
      return unless form_or_missing?(original)

      env['CONTENT_TYPE'] = BINARY
    end

    def form_or_missing?(content_type)
      media_type = content_type.split(';').first.to_s.strip.downcase
      return media_type.empty? || FORM_TYPES.include?(media_type)
    end
  end
end
