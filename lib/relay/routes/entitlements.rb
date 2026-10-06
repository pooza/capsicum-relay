require_relative '../entitlement_gate'
require_relative '../store_verification'
require_relative '../base_app'

module Relay
  module Routes
    # 有償リレーの利用権 (capsicum#597 / #58)。**フェーズ 1（認証）。**
    #
    # ⚠⚠ **この route は誰も拒まない。**`/register` も `/push` も従来どおり通る
    # （ゲートはフェーズ 2 / #60、レシート検証はフェーズ 3 / #61 / #62）。ここで
    # 作るのは「誰から来たかを言えるようにする」ための記録だけ。
    #
    # ⚠⚠ **発行された token は「購入した証拠」ではない。**認証は共有シークレット
    # 1 本で、**そのシークレットはバイナリから取り出せる**（capsicum#1121 の
    # 「`RELAY_SECRET` は authorization boundary にできない」）。つまりこの
    # エンドポイントは実質的に開いており、**誰でも好きな `purchase_id` で
    # `unverified` の行を作れる**。フェーズ 3 でレシートを検証して初めて
    # `active` になる。
    #
    # **Apple / Google はその場で確かめる (#61 / #62)。**`purchase_id`（Apple は StoreKit の
    # transactionId、Google は purchaseToken）でストアの API を引き、状態を反映してから
    # 応答する。⚠ ストアに届かないときは `unverified` のまま返す（fail-open・判断は
    # [Relay::StoreVerification]）。Microsoft は後回し。
    class Entitlements < BaseApp
      # 前景の枠が埋まっていた回の `Retry-After`（秒）。検証 1 件は通常 1 秒前後。
      VERIFICATION_BUSY_RETRY_AFTER = 2

      post '/entitlements' do
        authenticate!
        require_fields!('store', 'purchase_id', 'device_id')
        validate_store!

        # ⚠⚠ **枠は行を作る前に取る** (#89・PR #90 の Codex P1)。取れない回は
        # 何も保存せずに 503 で断る（[reserve_verification!]）。
        token, verification = issue_and_verify(reserve_verification!)

        metrics.increment('relay_entitlement_token_total', {store: token['store']})
        log_event(
          'entitlement.issued',
          # ⚠ **`purchase_id` も `token` もログに出さない。**前者はストアの購入を
          # 名指しでき、後者はそのまま利用権として使える。切り分けに要るのは
          # 「どのストアの・どの商品が・端末いくつぶん」までで、個体は要らない。
          msg: "Entitlement token issued: #{token['store']} (#{token['status']})",
          store: token['store'],
          product_id: token['product_id'],
          status: token['status'],
          environment: token['environment'],
          verification: verification,
          device_count: settings.database
            .entitlement_tokens_for_purchase(token['store'], token['purchase_id']).size,
          latency_ms: latency_ms,
        )
        status 201
        entitlement_response(token).to_json
      end

      # 手元の token の**いまの状態**を読む (#80)。
      #
      # ⚠⚠ **`POST` を状態確認に使い回さないための口。**あちらは upsert なので
      # 冪等ではあるが、呼ぶたびに `relay_entitlement_token_total` が増え
      # `entitlement.issued` が出る —— **「発行の回数」を数えている counter が
      # 「画面を開いた回数」に汚染され、ゲートを閉じてよいかの判断材料が濁る。**
      #
      # ⚠ **副作用を持たない。**metrics もログも増やさず、⚠ **ストアへも
      # 問い合わせ直さない**（状態を書くのは通知と再確認の仕事・#61 / #62 / #63）。
      #
      # ⚠⚠ **404 と「失効」を混ぜない。**クライアントから見て「知らない token」
      # （端末の保存が壊れた / 消された）と「失効した token」（解約・支払い失敗）は
      # **別の状況**で、案内が違う。
      #
      # 🔴 **token を URL に載せない（PR #81 の Codex P2）。**`config/nginx.conf.sample`
      # は素の `access_log` を有効にしており、**リクエスト行に完全なパスが残る** ——
      # ⚠⚠ **token はそのまま利用権として使える capability** なので、
      # `/var/log/nginx/capsicum-relay-access.log` に平文で溜まることになる。
      # このファイル自身が「token はログに出さない」と書いているのと矛盾していた。
      # ⚠ **ヘッダは既定のログ書式に含まれない**ので `X-Entitlement-Token` で受ける。
      get '/entitlements' do
        authenticate!

        provided = header_token
        halt 400, {error: 'X-Entitlement-Token required'}.to_json if provided.nil?

        token = settings.database.find_entitlement_token(provided)
        halt 404, {error: 'Unknown entitlement token'}.to_json unless token

        entitlement_response(token).to_json
      end

      helpers do
        # `X-Entitlement-Token` を読む。無ければ nil。
        #
        # 🔴🔴 **encoding を UTF-8 へ直すのが本体（2026-09-28 に実測して判明）。**
        # **Puma / Rack がヘッダから作る String は `ASCII-8BIT`（バイナリ）**で、
        # ⚠⚠ **そのまま SQLite にバインドすると TEXT ではなく BLOB になる。**
        # `WHERE token = ?` は TEXT と BLOB を比べることになり、**行があっても
        # 永久に一致しない** —— 実際、直すまでこの口は 1 件も引けなかった。
        #
        # ⚠ **`request.env` から読むときだけの話。**`params`（URL 由来）と
        # `json_body`（JSON.parse 由来）は UTF-8 なので起きない。
        # ⚠ `authenticate!` の `X-Relay-Secret` は**文字列比較**なので影響が無い
        # （ASCII 同士の `==` は encoding が違っても true）。**SQL へ渡す値だけ**が
        # 壊れるので、⚠⚠ **気づきにくい。**
        def header_token
          raw = request.env['HTTP_X_ENTITLEMENT_TOKEN']
          return nil if raw.nil?

          value = raw.dup.force_encoding(Encoding::UTF_8)
          return nil unless value.valid_encoding?
          return nil if value.empty?

          return value
        end

        # 行を作り、[mode] に従って確かめる。戻り値は [verified] と同じ。
        # ⚠ **取った枠は、例外で抜けた回も必ず返す**（返さないと以後の購入が全部断られる）。
        def issue_and_verify(mode)
          token = settings.database.issue_entitlement_token(
            store: json_body['store'],
            purchase_id: json_body['purchase_id'],
            product_id: json_body['product_id'],
            device_id: json_body['device_id'],
          )
          return verified(token, mode)
        ensure
          Relay::StoreVerification.release_foreground if mode == :reserved
        end

        # ストアのクライアントがあればその場で確かめる。戻り値は `[token, outcome]`
        # （確かめなかったときの outcome は nil）。
        #
        # ⚠ 検証で行が寄った（元の取引 ID の行が既にあった）ときは、**寄せた先の
        # token を返し直す**。クライアントの手元の token はそれで置き換わる。
        def verified(token, mode)
          store = token['store']
          return [token, nil] if mode == :none

          if mode == :deferred
            metrics.increment('relay_entitlement_verify_total', {store: store, outcome: 'deferred'})
            return [token, 'deferred']
          end

          outcome, entitlement_id = Relay::StoreVerification.verify!(
            settings,
            store: store,
            entitlement_id: token['entitlement_id'],
            purchase_ref: json_body['purchase_id'],
          )
          metrics.increment('relay_entitlement_verify_total', {store: store, outcome: outcome})
          return [
            settings.database.entitlement_token_for(entitlement_id, json_body['device_id']),
            outcome,
          ]
        end

        # この要求でストアをどう確かめるかを決め、要るなら前景の枠を取る (#89)。
        #
        # | 戻り値 | 意味 |
        # | --- | --- |
        # | `:none` | そのストアのクライアントが無い（確かめない・従来どおり） |
        # | `:reserved` | 枠を取った。⚠ **呼び出し側が必ず返す** |
        # | `:deferred` | 前景では確かめない構成（スレッドが 1 本）。行だけ残す |
        #
        # ⚠⚠ **枠が埋まっていたら、何も保存せずに 503 で断る。**この口は実質的に
        # 開いているので、断らずに行を作ると、でたらめな行を SQLite の速さで積める。
        # ⚠ **401 / 403 と区別できる形で返す** —— クライアントは一時的な失敗として
        # 送り直す（購入はストアに残っているので、失われるものは無い）。
        def reserve_verification!
          return :none unless Relay::StoreVerification.client_for(settings, json_body['store'])
          return :deferred if Relay::StoreVerification.foreground_limit.zero?
          return :reserved if Relay::StoreVerification.reserve_foreground

          metrics.increment('relay_entitlement_verify_total',
            {store: json_body['store'], outcome: 'busy'})
          # ⚠⚠ **断ったことを必ずログに残す**（capsicum v2.0 の 2 回目の差分レビュー）。
          # ここは `entitlement.issued` より手前で抜けるので、残さないと journald に
          # **何も出ない** —— counter は累積なので「いつ・どのストアで」が追えず、
          # 本番でクライアントが 503 を受けた回を、前後の行から推定するしかなかった。
          # ⚠ `purchase_id` は載せない（[post '/entitlements'] と同じ理由）。
          log_event(
            'entitlement.verification_busy',
            level: :warn,
            msg: "Entitlement verification refused (busy): #{json_body['store']}",
            store: json_body['store'],
            # ⚠ **埋まっている本数は載せない**（PR #92 の Codex P2）。断ったあとで
            # 読み直すと、その間に枠が返って 0 と記録されうる。断った時点では
            # 上限と同じなので、上限だけで足りる。
            limit: Relay::StoreVerification.foreground_limit,
            retry_after: VERIFICATION_BUSY_RETRY_AFTER,
          )
          headers 'Retry-After' => VERIFICATION_BUSY_RETRY_AFTER.to_s
          halt 503, {error: 'Verification busy', reason: 'verification_busy'}.to_json
        end

        def validate_store!
          return if Relay::Database::ENTITLEMENT_STORES.include?(json_body['store'])

          halt 400, {
            error: "store must be one of #{Relay::Database::ENTITLEMENT_STORES.join(', ')}",
          }.to_json
        end

        # クライアントへ返す形。
        #
        # ⚠ **内部 id を返さない。**クライアントが持つ必要があるのは `token` だけで
        # （`/register` に載せる・capsicum#1121）、行 id を渡すと「id で引ける」と
        # 誤解される導線ができる。
        #
        # ⚠ `purchase_id` は**返す**（送ってきた値なので新しい情報ではなく、
        # どの購入に対する応答かを突き合わせられる）。
        #
        # ⚠⚠ **`entitled` / `reason` を載せる（#63）。**`status` と `expires_at` を
        # 返すだけだと、**クライアントが同じ判定を書き直すことになる** ——
        # `status` が `active` のまま期限が過ぎた行（更新の通知を取りこぼした形）を
        # 「有効」と表示してしまい、**画面とゲートで別の結論が出る**。判定は
        # [Relay::EntitlementGate] の 1 か所に置く、が #60 からの方針。
        def entitlement_response(token)
          entitled, reason = entitlement_state(token)
          return {
            token: token['token'],
            store: token['store'],
            purchase_id: token['purchase_id'],
            product_id: token['product_id'],
            status: token['status'],
            expires_at: token['expires_at'],
            environment: token['environment'],
            entitled: entitled,
            reason: reason,
          }
        end

        # その行がいま利用権として通るか。戻り値は `[通るか, 理由]`。
        #
        # ⚠⚠ **[Relay::EntitlementGate.decide] ではなく [row_decision] を呼ぶ。**
        # あちらは `RELAY_ENTITLEMENT_ENFORCE` が false なら即 `enforce_off` で通す
        # ので、**enforce を立てる前は画面が常に「有効」になってしまう**。ここで
        # 知りたいのは「ゲートを閉じたらどう扱われるか」で、**いま閉じているかでは
        # ない**（設計書 2-4 の「閉じる前に測る」と同じ向き）。
        #
        # ⚠ プリセットの迂回もここでは見ない —— この口は**購入の状態**を返すもので、
        # 「プリセットだから通る」はその購入の性質ではない。
        def entitlement_state(token)
          return Relay::EntitlementGate.row_decision(token)
        end
      end
    end
  end
end
