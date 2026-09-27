# capsicum-relay 開発ガイド

## プロジェクト概要

capsicum（Mastodon / Misskey クライアント）向けのプッシュ通知リレーサーバー。
Mastodon / Misskey が送出する Web Push を受信し、APNs（iOS）/ FCM（Android）に変換して転送する。

- **技術スタック**: Ruby / Sinatra / Puma / SQLite
- **ホスティング**: Linode Nanode（Ubuntu 24.04 LTS）
- **リポジトリ**: <https://github.com/pooza/capsicum-relay>
- **本番稼働**: 2026-04（capsicum v1.18 と同時リリース）以降、プリセットサーバー向けに稼働中

## アーキテクチャ

```mermaid
flowchart LR
  subgraph sns[Mastodon / Misskey]
    srv[サーバー]
  end
  subgraph relay[capsicum-relay<br/>flauros.b-shock.co.jp]
    app[Sinatra + SQLite]
  end
  subgraph device[端末]
    ios[iOS / NSE]
    android[Android / FMService]
  end
  client[capsicum アプリ] -- /register<br/>shared_secret --> app
  srv -- Web Push<br/>VAPID --> app
  app -- APNs --> ios
  app -- FCM --> android
```

- Web Push の暗号化ペイロードは復号**しない**。Base64 のまま `custom_payload` / `data` に詰め、クライアント側（iOS は NSE / Android は `FirebaseMessagingService`）で復号して表示する（B 案採用）。[capsicum#336](https://github.com/pooza/capsicum/issues/336) 参照
- リレーが秘密鍵を持たないことで、将来の外部ユーザー向け有償提供時も E2E 前提を維持できる

### エンドポイント

| メソッド | パス | 認証 | 用途 |
|---------|------|------|------|
| GET | `/health` | なし | ヘルスチェック |
| POST | `/register` | X-Relay-Secret | デバイストークン登録（capsicum → リレー） |
| DELETE | `/register/:id` | X-Relay-Secret | 登録解除 |
| POST | `/push/:push_token` | なし（トークンの推測困難性で保護） | Web Push 受信（Mastodon / Misskey → リレー） |
| POST | `/entitlements` | X-Relay-Secret | 有償リレーの利用権の発行（capsicum#597 / [#58](https://github.com/pooza/capsicum-relay/issues/58)） |

### 通信フロー

```mermaid
sequenceDiagram
  autonumber
  participant C as capsicum
  participant S as Mastodon / Misskey
  participant R as capsicum-relay
  participant P as APNs / FCM
  C->>C: APNs / FCM デバイストークン取得
  C->>R: POST /register<br/>(token, device_type, account, server, device_id?)
  R-->>C: 201 Created<br/>(push_token を返す)
  C->>S: Web Push subscription 登録<br/>endpoint = relay/push/{push_token}
  Note over S: 通知イベント発生
  S->>R: POST /push/{push_token}<br/>(暗号化 body + Content-Encoding ヘッダ)
  R->>P: APNs(custom_payload) / FCM(data)<br/>に body(base64) / encoding / crypto_key / encryption を詰めて転送
  P-->>C: 端末に配信
  C->>C: NSE / FMService で復号して通知表示
```

### ライフサイクル異常時の挙動

| 状況 | 応答 | 意図 |
|------|------|------|
| `/push/:push_token` で未知のトークン | 410 Gone | Mastodon 側の subscription を自動 destroy させる（404 だと残り続けるため） |
| APNs が `BadDeviceToken` / `Unregistered` / `DeviceTokenNotForTopic` を返した | 410 Gone + DB 行削除 | device token 無効化。Mastodon に cleanup を促しつつ relay 側も掃除 |
| FCM が `UNREGISTERED` / `SENDER_ID_MISMATCH` を返した | 同上 | 同上。`INVALID_ARGUMENT` は request 側バグでも出るため誤削除回避に含めない |

### APNs / FCM 転送ペイロードのスキーマ

`/push/:push_token` で受けた Web Push を APNs (`custom_payload`) / FCM (`data`) の同形フィールドに詰めて転送する。capsicum の NSE (iOS) / FirebaseMessagingService (Android) はこのスキーマに従って復号する。

| キー | 型 | 出現 | 内容 |
|------|-----|------|------|
| `body` | string (base64) | 常時 | Web Push の生 body（暗号化済）。`strict_encode64` で URL-safe でない通常の base64 |
| `encoding` | string | 常時 | `Content-Encoding` ヘッダ値（`aes128gcm` or `aesgcm`）。空文字なら非暗号化（通常はあり得ない） |
| `server` | string | 常時 | 登録時の `server`（Mastodon/Misskey ホスト名） |
| `account` | string | 常時 | 登録時の `account`（`username@host` 形式） |
| `crypto_key` | string | `aesgcm` のとき | `Crypto-Key` ヘッダ原文。`dh=...;p256ecdsa=...` などキー付きの値 |
| `encryption` | string | `aesgcm` のとき | `Encryption` ヘッダ原文。`salt=...` を含む |

#### 復号の実装上の注意

- **aes128gcm (RFC 8291)**: body 先頭に `salt` (16 byte) / `rs` (4 byte) / `idlen` (1 byte) / sender public key が前置されているため、body のみで復号可能。Mastodon 4.x / 現行 Misskey はこちら
- **aesgcm (legacy RFC 8188 draft 03)**: salt は `Encryption` ヘッダ、sender public key は `Crypto-Key` ヘッダの `dh=` パラメータに入っているため、これらも参照しないと復号できない。古い Mastodon フォーク / 一部 Misskey で使用される可能性あり
- **VAPID ヘッダ**: capsicum-relay は VAPID `Authorization` ヘッダを転送しない（push service 側で consume するもので、クライアント復号には不要）
- **TTL / Topic / Urgency**: Web Push 仕様のヘッダは転送しない（通知表示の用途なし）

## データモデル（SQLite）

`subscriptions` テーブルは `(token, account, server)` 複合ユニーク。同一端末に複数アカウントを登録した場合、各アカウントに独立した行と `push_token` が割り当てられる（1 デバイス N アカウント対応、[#3](https://github.com/pooza/capsicum-relay/issues/3) で実装）。

```mermaid
erDiagram
  subscriptions {
    INTEGER id PK
    TEXT token "APNs/FCM device token"
    TEXT push_token UK "relay 内部トークン（/push/:push_token で参照）"
    TEXT device_type "ios or android"
    TEXT account "username@host"
    TEXT server "Mastodon/Misskey host"
    TEXT device_id "client のインストール単位 ID（nullable）"
    TEXT created_at
    TEXT updated_at
  }
```

`UNIQUE(token, account, server)` + `UNIQUE(push_token)`。`push_token` は `SecureRandom.hex(32)`（64 文字 hex）。旧スキーマ（`UNIQUE(token)`）からの移行は起動時に自動で走る。

### device_id による dedup（[#15](https://github.com/pooza/capsicum-relay/issues/15)）

`UNIQUE(token, account, server)` だけだと、**デバイスの push トークンが更新されたとき衝突せずに新しい行ができ、旧行が孤児として残る**。旧トークンがまだ生きていて上流が両方に送る間は同一デバイスに二重 push が届き、時間とともに悪化する。

`(account, server, device_type)` に潰す案は採れない。実データに iPhone + iPad のように**全アカウントで 2 トークンを一貫保持して両方更新し続けている運用**があり、潰すと最後に登録した端末しか通知を受け取れなくなる。

そこで client が[インストール単位の安定 ID](https://github.com/pooza/capsicum/issues/932)（乱数 UUID・`shared_preferences` 保存）を `device_id` として送り、relay はそれをキーに upsert する。

- **列は nullable**。`device_id` を送らない旧クライアントは従来どおり `token` をキーに動く
- 実質的な `UNIQUE(account, server, device_id)` は**部分インデックス** `idx_subscriptions_device ... WHERE device_id IS NOT NULL` で張る（SQLite はテーブル制約に `WHERE` を書けない）
- 既存行は移行時に埋められないので `NULL` のまま。**次回 register で埋まる**のを待つ

`device_id` 付き register がどの行を上書きするかは順序に意味がある。

1. **今のトークンを持つ行**があればそれ。上流が現に push している行なので、`push_token` を保ったまま `device_id` を埋める。トークンを書き換えないので `UNIQUE(token, account, server)` に触れない。旧クライアントからの移行はここを通る
2. 無ければ**同じ `device_id` の行**。これがトークン更新のケースで、行を増やさず `token` だけ差し替える
3. どちらも無ければ新規 INSERT

1 と 2 が別の行を指すのは、トークンが一度離れて戻る場合だけで実運用では起きない。起きたときは部分インデックス違反になるため、古い方（2 の行）を畳んで 1 を残す。畳んだ行の `announcement_subscriptions` は FK の CASCADE で消える点に注意。

## 有償リレーの利用権（capsicum#597・フェーズ 1）

⚠⚠ **現状は誰も拒まない。**`/register` も `/push` も従来どおり通る。ゲートは
[#60](https://github.com/pooza/capsicum-relay/issues/60)（フェーズ 2）、レシート検証は
[#61](https://github.com/pooza/capsicum-relay/issues/61) / [#62](https://github.com/pooza/capsicum-relay/issues/62)（フェーズ 3）。
正本は capsicum の [`docs/paid-relay-plan.md`](https://github.com/pooza/capsicum/blob/develop/docs/paid-relay-plan.md)。

```mermaid
erDiagram
  entitlements ||--o{ entitlement_tokens : "1 購入 N 端末"
  entitlements {
    INTEGER id PK
    TEXT store "apple / google / microsoft"
    TEXT purchase_id "ストアの購入識別子"
    TEXT product_id
    TEXT status "unverified / active / grace / expired / revoked"
    TEXT expires_at
  }
  entitlement_tokens {
    INTEGER id PK
    TEXT token UK "opaque・クライアントが /register に載せる"
    INTEGER entitlement_id FK
    TEXT device_id "subscriptions.device_id と同じ値"
  }
```

### ⚠⚠ `unverified` を許可側に入れない

`POST /entitlements` の認証は共有シークレット 1 本で、**そのシークレットはバイナリから取り出せる**（[capsicum#1121](https://github.com/pooza/capsicum/issues/1121)）。つまりこのエンドポイントは実質的に開いており、**誰でも好きな `purchase_id` で `unverified` の行を作れる**。フェーズ 3 でレシートを検証して初めて `active` になる。

### ⚠ 判定は `subscriptions.device_id` から引く

```text
/push/{push_token} → subscriptions（push_token UNIQUE）
                   → subscriptions.device_id
                   → entitlement_tokens（device_id）
                   → entitlements.status
```

クライアントが `/register` に載せてくる `entitlement_token` は**観測のため**に記録するだけで、判定には使わない。⚠ **`device_id` が NULL の行（旧クライアント）は利用権を引けない。**

### ⚠ `subscriptions` に列を足さない

あのテーブルは CHECK / UNIQUE を変えるたびに `rebuild_subscriptions_table!` が要り、**その組み替えは過去に子テーブルの FK を壊している**（`repair_announcement_subscriptions_fk!` が今も居座っているのがその跡・[capsicum#468](https://github.com/pooza/capsicum/issues/468)）。**課金の都合で push の中核テーブルを組み替えない。**

### ⚠ `status` に CHECK を付けない

[#63](https://github.com/pooza/capsicum-relay/issues/63) で扱う状態（更新・失効・返金・支払い猶予・課金リトライ）は**これから増える**。CHECK にすると状態を 1 つ足すたびにテーブル組み替えになり、`subscriptions` で踏んだ罠を新しいテーブルで再現する。検査は `Relay::Database::ENTITLEMENT_STATUSES` で行う。

### プリセット判定の写し

`lib/relay/preset_servers.rb` は capsicum の `packages/capsicum/lib/src/preset_servers.dart` の**写し**。⚠⚠ **2 箇所に同じ一覧がある。**

- ⚠ **クライアントに判定させられない。**ゲートは「非プリセット かつ 利用権なし」で閉じるので、申告に委ねると書き換えるだけで抜けられる
- ⚠⚠ **ズレると、載っていないプリセットサーバーの利用者がフェーズ 3 で止まる。**`test/preset_servers_test.rb` が件数を固定しているので、片方だけ増やすとテストが落ちる
- 設定の `extra_preset_hosts` は**足すことしかできない**（置き換えにすると、設定を書き忘れたデプロイで全登録が非プリセット扱いになる）

### 認可ゲート（[#60](https://github.com/pooza/capsicum-relay/issues/60)・フェーズ 2）

⚠⚠ **既定では何も閉じない。**`RELAY_ENTITLEMENT_ENFORCE=true` を立てたときだけ判定する。**本番で立てるのはフェーズ 3 の決定**で、⚠ **立てる前に下の観測を読み直すこと**。

判定は `Relay::EntitlementGate.decide` の 1 か所で、`/register` と `/push` の両方が通る。⚠ **2 か所に書くと片方だけ閉じる**（登録は拒むのに既存の購読は叩き続ける）。

| 順 | 条件 | 結果 |
| --- | --- | --- |
| 1 | `RELAY_ENTITLEMENT_ENFORCE` が `true` でない | allow（`enforce_off`） |
| 2 | プリセットホスト | allow（`preset`）⚠ **判定に入る前に抜ける** |
| 3 | その端末に `active` / `grace` の利用権がある | allow（`entitled`） |
| 4 | それ以外 | **deny**（`no_entitlement`） |
| — | 判定中に例外 | ⚠⚠ **allow**（`error`）＝ fail-open |

拒んだときの応答:

| route | status | 理由 |
| --- | --- | --- |
| `/register` | **403** `{"reason":"entitlement_required"}` | ⚠ 401（シークレット違い）と区別できる形にする |
| `/push` | **410 Gone** | ⚠⚠ Mastodon / Misskey が購読を掃除する。黙って 200 を返すと**失効後も永久に叩かれる** |

⚠ **`/register` は登録してから判定する。**行を作らずに拒むと、ゲートを閉じた瞬間に「誰が止まったか」が DB から分からなくなる（#59 の観測の母数が消える）。配送は `/push` で止まるので、行が残っていても通知は出ない。

⚠ **`/push` が 410 を返しても `subscriptions` の行は消さない。**購入が復活したらクライアントの再登録で同じ行（同じ `push_token`）が使われる。消すと `announcement_subscriptions` も CASCADE で消える。⚠ **復帰には再登録が要る**（capsicum#1123 の導線）。

#### ⚠⚠ `unverified` を許可側に入れない

`POST /entitlements` は共有シークレットしか見ておらず、**そのシークレットはバイナリから取り出せる**（capsicum#1121）。**誰でも `unverified` の行を作れる**ので、入れるとゲートが無意味になる。`test/entitlement_gate_test.rb` が固定している。

#### ⚠⚠ 410 で購読が消えることは実測済み（2026-09-27）

設計書は「410 が正しい」と書いていたが**実測していなかった**。ステージングで踏んで確定させた。

**フォークのソース**（推測で語らないための一次情報）:

| | 購読を消す条件 |
| --- | --- |
| **Mastodon** (`Web::PushNotificationWorker#send`) | ⚠ **`408` / `429` 以外の 4xx すべて** |
| **Misskey** (`PushNotificationService`) | ⚠⚠ **`410` だけ**。403 / 404 では消さず**永久に叩き続ける** |

→ **両方に効くのは 410 だけ**なので、ゲートの拒否は 410 で返す。

**ステージングでの実測**（st2.mstdn.b-shock.org = dev24 → st.relay）:

1. 既存の購読に触らず、**relay が知らない push_token を指す購読を 1 件作った**
2. `Web::PushNotificationWorker` を同期実行 → nginx のアクセスログに `POST /push/… 410`
3. **購読が destroy された**（既存 2 件は無傷）

⚠ **st2.misskey.delmulin.com → st.relay の push は直近 7 日で 0 件**（購読行はあるが通知が発生していない）。**Misskey 側のライブ確認は未了**でソース読みのみ。

#### ⚠ `reason="error"` が 0 でないあいだゲートは効いていない

fail-open なので拒まれず、**metrics を見ないと気付けない**。`entitlement.gate` のログは **warn** で出る。

```console
$ curl -s -H "X-Relay-Secret: $SECRET" https://relay.capsicum.shrieker.net/metrics \
    | grep relay_entitlement_gate_total
```

### 観測（[#59](https://github.com/pooza/capsicum-relay/issues/59)）

`relay_register_entitlement_total{preset,entitlement,token}` が、フェーズ 3 でゲートを閉じたときに誰が止まるかを先に示す。

```console
$ curl -s -H "X-Relay-Secret: $SECRET" https://relay.capsicum.shrieker.net/metrics \
    | grep relay_register_entitlement_total
```

- `preset="no"` かつ `entitlement="none"` … **止まる候補**
- `token="mismatch"` … ⚠ **token を送れているのに止まる**いちばん分かりにくい形（別の端末の token を持っている）
- `token="unknown"` … relay が知らない token（別の relay 向け・手で作った値・DB を戻した後）

## コーディング規約

### RuboCop

モロヘイヤ由来の `.rubocop.yml` を適用。`bundle exec rubocop` がクリーンであることを PR マージの最低条件とする。

### RuboCop に含まれない個人規約

以下はユーザーから都度指示される。指示があり次第ここに追記する。

- メソッド末尾でも `return` を省略しない（暗黙のreturnを使わない）。ただし初期化・マイグレーション等の「戻り値が意味を持たない副作用専用メソッド」は除く（モロヘイヤと同じ運用）
- インデントは常に2スペース。見栄えのための位置揃え（代入の右辺にcase/if式を置いて深くインデントする等）は使わない。`x = case ...` ではなく、各分岐内で個別に代入する
- Sinatra の `configure do` / `helpers do` はメソッド定義を束ねるブロックであり、行数で括らない。`Metrics/BlockLength` の `AllowedMethods` に追加してある
- Sinatra の route ブロック（`get '/xxx' do ... end`）の最終値は暗黙 return のままにする。`return` はブロック内でエンクロージングメソッドからの return になるため使わない。途中離脱は `halt` を使う

## テスト

**本リポジトリに CI は無い。**`bundle exec rake test` と `bundle exec rubocop` をローカルで通すことが唯一の担保になる。

### 配信の「配線」を足したら変異テストを回す

device_type やクライアントの対応を広げる変更（`AnnouncementWorker#deliver` の `case`、`PushHelpers#push_client_for` の分岐、payload 組み立ての分岐など）は、**足した行を消してもテストが 1 件も落ちない**形になりやすい。購読行はあるのに 1 通も届かず、例外にならないのでログにも出ないためで、[#36](https://github.com/pooza/capsicum-relay/issues/36) Phase 2 で実際に踏んだ（capsicum 側の同型は pooza/capsicum#919）。

- 配線を足したら、**その行を 1 つずつ壊してテストが落ちることを確認する**。落ちなければテストが配線を見ていない
- 「どのクライアントを渡すか」の決定を `deliver` の `case` と同じファイルに寄せ（`AnnouncementWorker.from_settings` がその形）、device_type ごとの導通テストを持たせる
- ⚠ 変異テストで `git checkout <file>` を使うと**未コミットの実装ごと巻き戻る**。壊す前にコミットしておくこと

### Ruby の作業は macOS 端末で行う

Windows 実機（capsicum の Windows 機能検証機）に Ruby を入れて `rake test` を回す案は採らない。**`Gemfile.lock` に Windows プラットフォームの行が載り、端末間で往復する**ため（capsicum の `pubspec.lock` ping-pong と同型）。Windows 側で relay の変更が必要になったときは、差分を Issue のコメントに置いて macOS 端末へ引き継ぐ。

## インフラ

| 項目 | 値 |
|------|-----|
| ホスト名 | flauros.b-shock.co.jp |
| 公開ドメイン | relay.capsicum.shrieker.net |
| OS | Ubuntu 24.04 LTS |
| スペック | 1 vCPU / 1GB RAM / 25GB SSD |
| SSH | `deploy@flauros.b-shock.co.jp` |
| デプロイパス | `/home/deploy/repos/capsicum-relay` |
| Ruby | rbenv 管理 |
| プロセス管理 | systemd (`capsicum-relay.service`)。⚠ **unit の正本は chubo2 の cookbook**（`app/cookbooks/capsicum-relay/templates/capsicum-relay.service.erb`）。本リポジトリの `config/capsicum-relay.service.sample` はサンプルで、直しても実機には反映されない（#29） |
| リバースプロキシ | nginx（HTTPS 終端、Let's Encrypt 自動更新） |
| Puma | `127.0.0.1:9292`（nginx 背後） |

### ⚠⚠ ブランチ運用（2026-09-27 決定・[#68](https://github.com/pooza/capsicum-relay/issues/68)）

**ブランチ 2 本とホスト 2 台を 1 対 1 に対応させる。**

| ブランチ | デプロイ先 | 保護 |
| --- | --- | --- |
| `develop` | **triton**（ステージング・`st.relay.capsicum.shrieker.net`） | なし（直 push 可） |
| `main` | **flauros**（本番・`relay.capsicum.shrieker.net`） | ⚠⚠ **PR 必須 + `enforce_admins: true`** |

```text
feature（任意）→ develop → triton へデプロイして寝かせる
                    ↓ PR（⚠ ここで @codex review）
                  main → flauros へデプロイ
```

⚠⚠ **`main` へは直 push できない**（2026-09-27 に `enforce_admins: true` にした）。以前は保護が入っていても**管理者は素通りでき**、実際に [#58](https://github.com/pooza/capsicum-relay/issues/58)〜[#55](https://github.com/pooza/capsicum-relay/issues/55) の 5 回とも素通りで main へ入れてしまった。**規約では止まらなかったのでフックにした**（capsicum 側の `.claude/hooks/deny-shell-loops.sh` と同じ考え方）。

⚠ **急いでいても段取りは端折れない**（2026-09-27 pooza）。緊急時に本当に直 push が要るなら **`enforce_admins` を一時的に false にしてから**入れ、**戻す**。

```bash
gh api -X DELETE repos/pooza/capsicum-relay/branches/main/protection/enforce_admins  # 外す
gh api -X POST   repos/pooza/capsicum-relay/branches/main/protection/enforce_admins  # 戻す
```

⚠ **Codex は `@codex review` を打った時だけ走る。**追加コミットや force-push では発火しない。⚠ 未登録リポジトリや base SHA 取得不能で**空振りする**ことがあるので、空振りなら 5 観点レビュー（capsicum の `/release-review`）に切り替える。

### デプロイ手順

⚠ **ステージング（triton）を先に、本番（flauros）を後に。**ホストごとに**見るブランチが違う**。

```bash
# ステージング
ssh deploy@triton.b-shock.local
cd ~/repos/capsicum-relay && git pull   # develop
bundle install
sudo systemctl restart capsicum-relay

# 本番（develop → main の PR をマージした後）
ssh deploy@flauros.b-shock.co.jp
cd ~/repos/capsicum-relay && git pull   # main
bundle install
sudo systemctl restart capsicum-relay
```

⚠ **restart 直後の `curl` は 502 を返す**（Puma が listen するまで 15〜20 秒）。下の「疎通確認」を参照。

### 疎通確認

```bash
curl https://relay.capsicum.shrieker.net/health
# => {"status":"ok","subscriptions":N}
```

⚠⚠ **restart の直後は 502 が返る。**Puma が listen するまで **15〜20 秒**かかる（起動ログの `Started capsicum-relay.service` から `Listening on http://127.0.0.1:9292` までの実測が 17 秒）。**3 秒後に curl して 502 を見て「起動に失敗した」と誤診しやすい。**

`journalctl -u capsicum-relay -n 20` に `Listening on` が出ているかを見るか、成功するまで待つ形にする:

```bash
for i in $(seq 1 20); do
  curl -sS -m 10 https://relay.capsicum.shrieker.net/health | grep -q '"status":"ok"' && break
  sleep 5
done
```

⚠ **ステージングと本番の `revision` を並べて見ると、デプロイの逆転が検出できる**（2026-09-13 に実際に検出した）。⚠ ステージングは購読が小さく `supporters` は 0 なので、数値が違っても異常ではない。

### ⚠⚠ 配送は非同期（[#55](https://github.com/pooza/capsicum-relay/issues/55)）

**受信して即 `202` を返し、送信はワーカーで行う。**設計と理由は `lib/relay/push_queue.rb` の doc が正本。

配送が同期だったので、**遅い 1 通が puma のスレッドを占有していた**（`workers 0` / `threads 2` ＝ 同時に 2 通・Windows は 1 通 2,056ms）。7 日の実測で **Windows が総処理時間の 88%** を占め、**利用者数ではなく Windows が relay の容量を決めていた**。

| env | 既定 | 何 |
| --- | --- | --- |
| `PUSH_QUEUE_CAPACITY` | 200 | 積める通数。⚠ **深くしない**（詰まりに気付かない時間と、再起動で失う通数が増える） |
| `PUSH_QUEUE_WORKERS` | 2 | 配送の並行数。⚠⚠ **`HttpConnectionPool::MAX_IDLE_PER_HOST` と揃える**（超えたぶんは checkin で閉じられ、[#54](https://github.com/pooza/capsicum-relay/issues/54) の接続再利用が効かなくなる） |

#### ⚠⚠ 上流へ結末を返せなくなった、への答え

`202` を返した後に配送するので、`gone`（device token 無効）で **その場では 410 を返せない**。代わりに relay 側の行を落とし、**次の push が `410 Unknown push token` を返す**ことで上流の購読が掃除される。⚠ **1 通だけ「受け取ったのに届かない」通知が出る**のは承知の上のコスト。

#### ⚠ 再試行はしない（実測に基づく）

本番 30 日の `failed` 36 件は **android × FCM 400 が 25 件**（恒久的失敗）/ windows unknown 10 / no_response 1。⚠⚠ **再試行で救えるものがほぼ無い。**しかも同期のときは 502 を返して **Mastodon に 5 回 retry させていた** ＝ FCM 400 を 5 回投げ直していた。⚠ **APNs / FCM の 5xx が出るようになったら入れ直す**（30 日で 0 件）。

#### ⚠ 詰まりは `queued_ms` に出る

`latency_ms` は 1 通あたりの配送時間なので、**詰まっても変わらない**。`push.result` の `queued_ms`（キューで待った時間）と `relay_push_total{outcome="rejected"}` を見る。

#### ⚠⚠ 停止時に吐き切る

`config.ru` が `Relay::App.install_shutdown_hook!` を呼ぶ。⚠ **`configure` の中で `at_exit` を登録してはいけない** —— `minitest/autorun` より後に登録されるぶん**先に走り、テストが 1 件も動く前にキューが閉じる**。

⚠ 効いているのは `join`。**`SizedQueue#close` は積まれているものを捨てない**（`pop` は残りを返し切ってから nil・Ruby 4.0.6 で実測）。

### ⚠⚠ `/push` が返すステータスの選び方（[#66](https://github.com/pooza/capsicum-relay/issues/66)）

**ステータスは「上流が購読を消すか」で決まる。**配信結果を素直に写してはいけない。

| | 購読を消す条件 |
| --- | --- |
| **Mastodon** `Web::PushNotificationWorker#send` | ⚠ **`408` / `429` 以外の 4xx すべて** |
| **Misskey** `PushNotificationService` | ⚠⚠ **`410` だけ** |

⚠ **[#55](https://github.com/pooza/capsicum-relay/issues/55) で配送が非同期になったので、ステータスは「受け取ったか」しか言えなくなった。**配送の結末はログと counter にだけ出る。

| 場面 | 返す | なぜ |
| --- | --- | --- |
| 受け取った | **202** | ⚠ 200 ではない —— 配送したかはまだ分からない |
| 知らない push_token | **410** | ⚠ **意図して消す**。上流の stale な購読を掃除させる |
| 利用権なし（[#60](https://github.com/pooza/capsicum-relay/issues/60)・既定は無効） | **410** | 同上 |
| 重複（dedup） | **200** | 4xx / 5xx だと retry や destroy を誘発する |
| クライアント未設定 | **503** | ⚠ **同期で返す。**202 に隠れると設定漏れに気付けない |
| キューが満杯 | **503** | ⚠ 黙って捨てない。⚠⚠ **4xx にしてはいけない**（購読が消える） |

⚠⚠ **意図して消したいときだけ 4xx（410）を返す。**#66 は `oversized` で 413 を返しており、「購読は健全なので残す」という**想定と正反対**に動いていた（Mastodon が destroy する）。⚠ **429 も選べない** —— destroy は免れるが `raise` になって sidekiq が retry し、**同じ oversized な payload は再送しても必ず失敗する**。

`test/push_outcome_status_test.rb` が結末とステータスの対応を固定している。

### 配信不達の切り分け（journald を読む）

「プッシュが届かない」を疑ったとき、**Sentry のイベント数だけで判定してはいけない**。flauros の journald には成功も失敗も残っているので、必ず突き合わせる。

#### なぜ Sentry だけでは足りないか

- relay が Sentry へ上げているのは**失敗側だけ**。成功は journald と `/metrics` にしか出ないので、Sentry を見ると失敗だけが並び、母数が見えない
- WNS の `dropped` は**端末がオフライン / スリープで受け取れなかった**という正常系。PC を消している時間が長い利用者ほど積み上がるので、件数の多さは不具合の証拠にならない
- capsicum 側の `push.wns_bgtask: bgtask.shown` は、bg task が LocalState に書いた記録を**次回アプリ起動時に**回収して送る方式。**「出ていない ＝ トーストが出ていない」ではない**（アプリを起動していないだけ）

#### 手順

まず `/metrics` で母数と内訳を見る（#2）。14 日ぶんの journald を走査する前に、「そもそも relay に届いているか / 送れているか」がここで分かる。

```bash
curl -s -H "X-Relay-Secret: $SECRET" https://relay.capsicum.shrieker.net/metrics \
  | grep relay_push_total
```

`relay_push_total{device_type,outcome}` の `outcome` は `success` / `deduped` / `degraded` / `gone` / `oversized` / `failed` / `wns_<status>`。⚠ **counter はプロセス再起動でゼロに戻る**（in-memory）。再起動の位置は `/health` の `revision` の変化で分かる。

期間や個別アカウントを見るときは journald を読む。ログは **1 行 = 1 JSON**（#2）。

```bash
ssh deploy@flauros.b-shock.co.jp
journalctl -u capsicum-relay --no-pager --since "-14 days" -o cat \
  | grep '"event":"push.result"' \
  | jq -r '[.ts, .device_type, .outcome, .account] | @tsv'
```

⚠ **従来の grep もそのまま効く。** JSON の中に人間向けの `msg`（`Pushed to windows: <account>` / `WNS delivered but dropped: <account>`）を同じ文言で残してあるため。

```bash
journalctl -u capsicum-relay --no-pager --since "-14 days" -o short-iso \
  | grep -E "Pushed to windows:|WNS delivered but dropped:"
```

`outcome=success`（＝`Pushed to <device_type>:`）が成功、`outcome=wns_dropped`（＝`WNS delivered but dropped:`）が drop。アカウント別に数えて成功率を出し、さらに**時刻（JST）別の分布**を見る。

`request_id` は応答の `X-Request-Id` と同じ値で、Sentry イベントにも同名の tag が乗る。特定の 1 リクエストを追うときはこれで 3 者を突き合わせる。

#### 判定基準

| 観測 | 読み方 |
| --- | --- |
| 成功が特定の時間帯に集中し、それ以外は drop 一色 | **端末の電源パターン**。正常 |
| 全時間帯に成功が分散している | 常時通電の端末。正常 |
| 成功が 1 件も無い | ここで初めて端末側（bgtask 登録・チャンネル失効）を疑う |

成功率そのものは端末間で大きく開く（実測で 11%〜84%）が、**差の正体は「PC がついている時間の長さ」**であって端末の健全性ではない。低い成功率だけを見て不具合と判断しないこと。

journald は 2026-04-17（サービス開始時）から全期間残っている。経緯は [pooza/capsicum#931](https://github.com/pooza/capsicum/issues/931)。

#### お知らせ（announcement）が届かないとき

⚠ **通常の push とは別経路・別 counter**。上流から来た Web Push を中継する通常経路と違い、お知らせは worker が各サーバーを polling して自分で送る。`relay_push_total` には**乗らない**（#44）。

見分けたい 3 択は「① そもそも購読が無い」「② 送ったが失敗した」「③ 送って成功した」で、どれも journald だけで分かる。

```bash
# ① server ごとの fan-out。購読 0 件でも 1 行出る
journalctl -u capsicum-relay --no-pager -o cat \
  | grep '"event":"announcement.dispatch"' \
  | jq -r '[.ts, .server, .announcement_id, .subscriptions, (.device_types | tostring)] | @tsv'

# ②③ 配送 1 通ごとの結末
journalctl -u capsicum-relay --no-pager -o cat \
  | grep '"event":"announcement.push.result"' \
  | jq -r '[.ts, .device_type, .outcome, .account, .reason] | @tsv'
```

`/metrics` 側は `relay_announcement_push_total{device_type,outcome}`。`outcome` のラベル値は `relay_push_total` と揃えてあるので、「中継は成功しているのにお知らせ配信だけ落ちている」を並べて比較できる。お知らせ固有の値は次の 2 つ:

| outcome | 読み方 |
| --- | --- |
| `unconfigured` | その device_type の push クライアントが未設定（`reason=client_unset`）か、register が受け付ける種別に配送が追いついていない（`reason=unknown_device_type`）。**購読行はあるのに 1 通も届かない**状態で、設定漏れ・配線漏れを疑う |
| `no_result` | push クライアントが結果 Hash を返さなかった。実装の不整合 |

⚠ **失敗しても再送はされない。** `mark_announcement_seen` は server 単位なので、現状は「失敗した 1 通が失われたことが数字とログに残る」ところまで（#44 の C 案）。購読単位の再送は失敗率を見てから設計する。

### WNS の接続再利用を測る（[#54](https://github.com/pooza/capsicum-relay/issues/54)）

`push.result` の **`conn`** が、その 1 通で WNS への HTTP 接続を使い回せたかを表す（`reused` / `opened` / `reopened`。WNS 以外は出ない）。⚠ **`latency_ms` と同じ行にあるのが眼目** —— 接続確立にかかっていた 690ms が実際に消えているかは、この 2 つを並べないと分からない。

```bash
# conn ごとの件数と平均 latency（ヒット率と削減幅を同時に見る）
journalctl -u capsicum-relay --no-pager -o cat --since '-7 days' \
  | grep '"event":"push.result"' \
  | jq -r 'select(.device_type == "windows") | [.conn, .latency_ms] | @tsv' \
  | awk -F'\t' '{n[$1]++; s[$1]+=$2} END {for (k in n) printf "%s\t%d\t%.0fms\n", k, n[k], s[k]/n[k]}'
```

| conn | 読み方 |
| --- | --- |
| `opened` | プールが空だった（新規に TCP + TLS）。**push の間隔がアイドル上限 55 秒より長いとこれになる**ので、平常時はこちらが多い |
| `reused` | 使い回せた。⚠ **狙いはこれの平均 latency が `opened` より約 690ms 小さいこと** |
| `reopened` | 使い回した接続が相手に閉じられていて、張り直して送り直した（`WNS connection was stale` の warn が同時に出る）。⚠ **多発するならアイドル上限 (`IDLE_TIMEOUT`) が WNS 側の keep-alive より長い** |

⚠⚠ **`reused` が出ているのに latency が下がらない場合は `keep_alive_timeout` を疑う。**`Net::HTTP` の既定は 2 秒で、それを超えて空いた接続は **Net::HTTP 自身が黙って張り直す**。プールは「再利用した」と言い続けるので、**計測だけが嘘になる**（`Relay::HttpConnectionPool#configure` で上げてある）。

## ディレクトリ構成

```text
capsicum-relay/
  docs/               # 開発ドキュメント
    CLAUDE.md          # 本ファイル
  app.rb               # Sinatra アプリ本体
  config.ru            # Rack エントリポイント
  lib/
    relay/
      database.rb      # SQLite ラッパー（自動マイグレーション）
      apns_client.rb   # APNs HTTP/2 クライアント（apnotic gem）
      fcm_client.rb    # FCM v1 API クライアント（googleauth gem）
  config/
    settings.yml.sample    # 設定ファイルテンプレート
    puma.rb                # Puma 設定
    capsicum-relay.service.sample # systemd ユニットの雛形（⚠ 稼働機の正本は chubo2 cookbook・#29）
    nginx.conf.sample      # nginx 設定テンプレート
  db/                  # SQLite データベース格納先
  Gemfile              # 依存 gem
```

## 設定

`config/settings.yml.sample` をコピーして `config/settings.yml` を作成する。
APNs / FCM のクレデンシャルは `.gitignore` で除外されている。

### 必要なクレデンシャル

| 項目 | 用途 | 配置先 |
|------|------|--------|
| APNs 認証キー（.p8） | iOS プッシュ通知送信 | settings.yml の `apns.key_path` |
| APNs Key ID | 同上 | settings.yml の `apns.key_id` |
| APNs Team ID | 同上 | settings.yml の `apns.team_id` |
| Firebase サービスアカウント JSON | Android プッシュ通知送信 | settings.yml の `fcm.service_account_path` |
| shared_secret | capsicum からの登録認証 | settings.yml の `shared_secret` |
| extra_preset_hosts | プリセット判定に**足す**ホスト（任意・capsicum#597） | settings.yml の `extra_preset_hosts` |

## 関連リポジトリ

| リポジトリ | 関係 |
|-----------|------|
| [capsicum](https://github.com/pooza/capsicum) | クライアント本体。リレーにデバイストークンを登録し、通知を受信する |
| [mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy) | モロヘイヤ。Ruby の運用知見・コーディング規約の共有元 |

## 関連 Issue

- [capsicum#52](https://github.com/pooza/capsicum/issues/52) — プッシュ通知リレー（本体 Issue、Stage 1 完了済み）
- [capsicum#314](https://github.com/pooza/capsicum/issues/314) — iOS APNs デバイストークン取得（完了）
- [capsicum#336](https://github.com/pooza/capsicum/issues/336) — プッシュ通知ペイロードの復号と通知内容の個別表示（Phase 1: 復号器、Phase 2: FCM 復号 + ローカル通知表示まで完了）
- [capsicum#355](https://github.com/pooza/capsicum/issues/355) — Misskey プッシュ登録を relay 経由にルーティング（Stage 2）
- [capsicum-relay#2](https://github.com/pooza/capsicum-relay/issues/2) — 可視性の強化（構造化ログ / メトリクス）
- [capsicum-relay#5](https://github.com/pooza/capsicum-relay/issues/5) — 受信時の `Content-Encoding` をログ出力

## 段階的リリース計画

詳細は capsicum の [push-relay-plan.md](https://github.com/pooza/capsicum/blob/develop/docs/push-relay-plan.md) を参照。

- **Stage 1**: Mastodon プッシュ通知（プリセットサーバー向け）— capsicum v1.18 で出荷済み
- **Stage 2**: Misskey プッシュ通知 — Phase 1（aesgcm 互換ヘッダ転送 / 復号器）完了、Phase 2（FCM 復号 + フォアグラウンド通知）完了。残タスクは capsicum#336 側にある
- **Stage 3**: 外部ユーザー向け有償提供 — 外部ユーザーの規模が確認されてから具体化。relay 側で課金ロジック・認可・サブスク管理が必要になる想定

## 現在の状態（2026-04-23）

capsicum v1.19.1 をもって、relay は iOS / Android いずれのプリセットサーバー向けにも本番稼働している。v1.20（プッシュ通知完成）で relay 側の観測性・運用性向上を進める。

### 完了済み

- [x] リポジトリ作成・雛形実装
- [x] flauros デプロイ・systemd 登録
- [x] nginx + Let's Encrypt 証明書（自動更新有効）
- [x] APNs クレデンシャル配置・本番動作確認
- [x] FCM クレデンシャル配置・本番動作確認
- [x] shared_secret 本番値設定
- [x] capsicum との結合テスト（Mastodon / Misskey 両方）
- [x] subscription-scoped スキーマ（1 デバイス N アカウント、[#3](https://github.com/pooza/capsicum-relay/issues/3)）
- [x] device token 無効化時の 410 Gone 応答（[#1](https://github.com/pooza/capsicum-relay/issues/1)）
- [x] aesgcm レガシー対応（Crypto-Key / Encryption ヘッダ転送、capsicum#336 Phase 1）
- [x] account の host 二重付与バグ修正（[#4](https://github.com/pooza/capsicum-relay/issues/4)）
- [x] RuboCop 適用・規約統一（モロヘイヤ規約ベース）

### v1.20 で進めるもの

- [ ] 構造化ログ / メトリクス / 失敗可視化（[#2](https://github.com/pooza/capsicum-relay/issues/2)）
- [ ] `/push/:push_token` 受信時の `Content-Encoding` をログ出力（[#5](https://github.com/pooza/capsicum-relay/issues/5)）
