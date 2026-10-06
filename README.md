# capsicum-relay

[capsicum](https://github.com/pooza/capsicum)（Mastodon / Misskey クライアント）向けのプッシュ通知リレーサーバー。Mastodon / Misskey が送出する Web Push を受信し、APNs（iOS / macOS）/ FCM（Android）/ WNS（Windows）に変換して転送する。

Ruby / Sinatra / Puma / SQLite。本番は `relay.capsicum.shrieker.net`。

## 何をするか

Mastodon / Misskey はアプリへ直接プッシュ通知を送れない。capsicum は端末のトークンをこのリレーへ登録し、リレーの URL を Web Push の送り先としてサーバーへ伝える。通知が起きるとサーバーがリレーへ Web Push を送り、リレーが端末の種類に合った配送サービスへ中継する。

- **暗号化されたペイロードは復号しない。**Base64 のまま端末へ渡し、端末側で復号して表示する。リレーは復号の鍵も、利用者のアクセストークンも持たない
- **プリセットサーバーの利用者は無償。**それ以外のサーバーの利用者は、capsicum のアプリ内で買う利用権が要る。誰が使えるかはリレーが判定する（[利用権の設計](docs/entitlements.md)）
- 登録から配送までの流れは [開発ガイドのシーケンス図](docs/CLAUDE.md#通信フロー) にある

## 動かすのに要るもの

| もの | 用途 |
| --- | --- |
| Ruby（版は `.ruby-version`）と Bundler | 実行環境 |
| `config/settings.yml` | `config/settings.yml.sample` をコピーして作る。各キーの意味はサンプルのコメントにある |
| APNs の認証キー / Firebase のサービスアカウント / WNS の Package SID | 送りたいプラットフォームのぶんだけ。無いプラットフォームは送れないだけで、起動はする |
| App Store / Google Play の検証用の鍵 | 利用権の購入を検証するとき。無ければ検証しない |

```bash
bundle install
bundle exec puma -C config/puma.rb
curl http://127.0.0.1:9292/health
```

設定の節と環境変数の一覧は [開発ガイドの「設定」](docs/CLAUDE.md#設定)。

## テスト

```bash
bundle exec rake test
bundle exec rubocop
```

実 APNs / FCM / WNS やストアの API には繋がず、分岐と配線を検証する minitest。⚠ **CI は無い。**この 2 つをローカルで通すことが唯一の担保になる。

## ブランチ

| ブランチ | デプロイ先 |
| --- | --- |
| `develop` | ステージング（`st.relay.capsicum.shrieker.net`） |
| `main` | 本番（`relay.capsicum.shrieker.net`）。⚠ **PR 必須・直 push 不可** |

デプロイは必ずステージングを先に通す。形と注意点は[開発ガイドの「ブランチ運用」「デプロイ手順」](docs/CLAUDE.md#インフラ)。

稼働中のコミットは `/health` で分かる。

```bash
curl -s https://relay.capsicum.shrieker.net/health
# => {"status":"ok","revision":"<コミット>","subscriptions":N,...}
```

## ドキュメント

- [開発ガイド](docs/CLAUDE.md) — 構成・エンドポイント・ペイロードのスキーマ・データモデル・規約・デプロイ・配送の運用
- [有償リレーの利用権](docs/entitlements.md) — 認可ゲート・プリセットの裏取り・レシート検証
- 進捗と残作業は [Milestones](https://github.com/pooza/capsicum-relay/milestones) と Issue が正本（capsicum 本体と同名の枠で動く）
