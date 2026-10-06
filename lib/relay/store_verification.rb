require_relative 'app_store_client'
require_relative 'database'
require_relative 'google_play_client'
require_relative 'store_errors'

module Relay
  # ストア（Apple / Google）の購入を API で確かめ、結果を `entitlements` へ反映する
  # (#61 / #62)。
  #
  # ⚠ **入口は 3 つ**（`POST /entitlements`・各ストアの通知の受け口・確かめ直しの
  # ワーカー）で、ストアも 2 つある。判断を複数か所に書くと片方だけ fail-open や
  # 順序の守りを忘れるので、**ここ 1 か所に置く**。ストアごとの違いはクライアント
  # （`purchase_status` を持つ）に閉じる。
  module StoreVerification
    # ストア名 → そのクライアントを持つ settings の名前。
    CLIENTS = {'apple' => :app_store, 'google' => :google_play}.freeze

    # 購入ごとの鍵（Codex P2・PR #75）。
    #
    # ⚠⚠ **「ストアから読む → 書く」を同じ行については 1 本ずつにする。**⚠ 付け替え前の
    # 行は購入ごとに別の行 ID を持つので、鍵だけでは足りない。古い結果での上書きは
    # ストアの時刻（`signed_at`）の比較が防ぐ（[Relay::Database#apply_entitlement_verification]）。
    #
    # ⚠ **全体で 1 本の鍵にしない。**ストアが遅いとき（タイムアウトまで最大 30 秒）に
    # puma の 2 本のスレッドが両方待たされ、**push の受け付けまで止まる**。
    #
    # ⚠⚠ **使い終わった鍵は消す** (#89)。行は誰でも作れる（`POST /entitlements`）ので、
    # 残すとでたらめな `purchase_id` の数だけ Mutex が溜まり続ける。⚠ **待っている
    # スレッドがいる間は消さない**（消すと後から来たスレッドが別の Mutex を作り、
    # 同じ行を 2 本で触る）ので、使っている数を一緒に持つ。
    LOCKS = {} # rubocop:disable Style/MutableConstant
    LOCKS_GUARD = Mutex.new
    Lock = Struct.new(:mutex, :users)

    def self.with_lock(entitlement_id, &)
      lock = LOCKS_GUARD.synchronize do
        entry = (LOCKS[entitlement_id] ||= Lock.new(Mutex.new, 0))
        entry.users += 1
        entry
      end
      begin
        return lock.mutex.synchronize(&)
      ensure
        LOCKS_GUARD.synchronize do
          lock.users -= 1
          LOCKS.delete(entitlement_id) if lock.users.zero?
        end
      end
    end

    # 呼び出したスレッドがその行の鍵を握っているか（テストが「鍵の中で数えているか」を見る口）。
    def self.lock_owned?(entitlement_id)
      return LOCKS_GUARD.synchronize {LOCKS[entitlement_id]&.mutex&.owned? || false}
    end

    # `POST /entitlements` がストアへ同時に問い合わせてよい本数 (#89)。
    #
    # ⚠⚠ **puma のスレッドを 1 本、必ず配送に残す。**あの口は実質的に開いていて
    # （共有シークレットはバイナリから取り出せる）、検証は 1 件あたり秒単位の同期 I/O
    # （Apple は Production → Sandbox の順に引き、タイムアウトは環境ごとに最大 15 秒）。
    # でたらめな `purchase_id` を並列に投げるだけで全スレッドが埋まり、**プリセット
    # 利用者の `/push` まで止まる**。
    #
    # ⚠ **枠が無いときは待たせず、確かめずに返す**（`deferred`）。行は `unverified` の
    # まま残り、通知の受け口か確かめ直しのワーカーが拾う ＝ ストアに届かなかった回
    # （`unavailable`）と同じ道。待たせると、結局そのスレッドが埋まる。
    #
    # ⚠ 通知の受け口とワーカーは数えない（前者は署名で送り主を確かめてから引く・
    # 後者は puma のスレッドを使わない）。
    FOREGROUND_GUARD = Mutex.new
    FOREGROUND = {busy: 0} # rubocop:disable Style/MutableConstant

    def self.foreground_limit
      threads = Integer(ENV.fetch('PUMA_THREADS', 2), exception: false) || 2
      return [threads - 1, 1].max
    end

    # 前景（`POST /entitlements`）からの検証。枠が無ければ `['deferred', entitlement_id]`。
    def self.verify_in_foreground!(settings, store:, entitlement_id:, purchase_ref:)
      acquired = FOREGROUND_GUARD.synchronize do
        next false if FOREGROUND[:busy] >= foreground_limit

        FOREGROUND[:busy] += 1
        true
      end
      return ['deferred', entitlement_id] unless acquired

      begin
        return verify!(
          settings, store: store, entitlement_id: entitlement_id, purchase_ref: purchase_ref
        )
      ensure
        FOREGROUND_GUARD.synchronize {FOREGROUND[:busy] -= 1}
      end
    end

    # アプリの設定にストアまわりを組み立てる（[Relay::BaseApp] の `configure` から呼ぶ）。
    #
    # - `apple_jws_verifier`: ⚠ **1 つを共有する**（API の応答と通知の両方が同じルート
    #   証明書で検証される・テストはここを差し替える）
    # - `app_store` / `google_play`: ⚠ **設定が無ければ nil ＝ 確かめない**（従来どおり
    #   `unverified` のまま・通知の受け口は 503）
    # - `entitlement_reverifier`: `unverified` のまま残った購入を確かめ直す（Codex P1・PR #75）
    def self.configure!(app)
      settings = app.settings
      app.set :apple_jws_verifier, Relay::AppleJwsVerifier.new
      app.set :app_store, Relay::AppStoreClient.from_config(
        settings.config, logger: settings.logger, verifier: settings.apple_jws_verifier
      )
      app.set :google_play,
        Relay::GooglePlayClient.from_config(settings.config, logger: settings.logger)
      # Pub/Sub の push に付く OIDC トークンの検証（テストはここを差し替える）。
      # ⚠ **Proc を `set` しない。**Sinatra は Proc の設定を読み出すたびに呼び出すので、
      # `call` を持つモジュールで渡す。
      app.set :google_oidc_verifier, Relay::GooglePlayClient::OidcVerifier
      app.set :entitlement_reverifier, Relay::EntitlementReverifier.start_from_settings(settings)
    end

    # そのストアのクライアント。設定されていなければ nil（確かめない）。
    def self.client_for(settings, store)
      name = CLIENTS[store]
      return nil unless name && settings.respond_to?(name)

      return settings.public_send(name)
    end

    # [purchase_ref] の購入を引き直し、[entitlement_id] の行へ反映する。
    # [purchase_ref] は Apple なら StoreKit の transactionId（元の取引でも更新後でも）、
    # Google なら purchaseToken。
    #
    # 戻り値は `[outcome, entitlement_id]`。検証で行が寄ったときは寄せた先の id。
    #
    # | outcome | 意味 | 行 |
    # | --- | --- | --- |
    # | `active` 等 | ストアの状態 | 反映した |
    # | `not_found` | ストアに無い購入 | 触らない（`unverified` のまま） |
    # | `unavailable` | ストアに届かない・鍵や権限が使えない | ⚠⚠ **触らない（fail-open）** |
    # | `invalid` | 署名・宛先が合わない | 触らない |
    # | `deferred` | 前景の枠が埋まっていた（[verify_in_foreground!] だけが返す） | 触らない |
    def self.verify!(settings, store:, entitlement_id:, purchase_ref:)
      return with_lock(entitlement_id) do
        verify_locked(settings, store, entitlement_id, purchase_ref)
      end
    end

    def self.verify_locked(settings, store, entitlement_id, purchase_ref)
      result = client_for(settings, store).purchase_status(purchase_ref)
      unless result
        # ⚠⚠ **数えるのは鍵の中**（PR #86 の Codex P2）。鍵の外で数えると、同じ購入の
        # **成功した検証と競合して、通ったばかりの行に連続を書き戻す**（連続が
        # [Relay::Database::NOT_FOUND_TERMINAL_DAYS] 日に達していれば `revoked` まで
        # 行く ＝ **正当な購読者が次の明示的な検証まで拒否されたままになる**）。
        # ⚠ **前景（`POST /entitlements` / 通知）でも数える** —— 掃除だけで数えると、
        # purchase_id を知っている者が前景で叩き続けるだけで終端を先送りできた。
        settings.database.record_entitlement_not_found(entitlement_id)
        return ['not_found', entitlement_id]
      end

      id = settings.database.apply_entitlement_verification(
        entitlement_id, verification_of(store, result)
      )
      return [result.status, id]
    rescue Relay::StoreUnavailable => e
      # ⚠⚠ **有効な購入を「確かめられなかった」だけで失効扱いにしない。**
      settings.logger.warn("Store verification unavailable (#{store}, state kept): #{e.message}")
      return ['unavailable', entitlement_id]
    rescue Relay::StoreResponseInvalid => e
      settings.logger.warn("Store response failed verification (#{store}): #{e.message}")
      return ['invalid', entitlement_id]
    end

    def self.verification_of(store, result)
      return Relay::Database::EntitlementVerification.new(
        store: store,
        purchase_id: result.purchase_id,
        product_id: result.product_id,
        status: result.status,
        expires_at: result.expires_at,
        environment: result.environment,
        signed_at: result.signed_at,
      )
    end
    private_class_method :verify_locked, :verification_of
  end
end

require_relative 'entitlement_reverifier'
