# capsicum-relay

[capsicum](https://github.com/pooza/capsicum)（Mastodon / Misskey クライアント）向けのプッシュ通知リレーサーバー。Mastodon / Misskey が送出する Web Push を受信し、APNs（iOS）/ FCM（Android）に変換して転送する。

Ruby / Sinatra / Puma / SQLite。Linode Nanode で運用中。`relay.capsicum.shrieker.net`。

## 仕組み

登録からプッシュ配信までの一連の流れは、[開発ガイドのシーケンス図](docs/CLAUDE.md#通信フロー) を参照。このリレーがやっていることは、その図がもっとも雄弁に語っている。

補足として、暗号化された Web Push ペイロードはリレーでは復号せず、Base64 のままクライアント（iOS NSE / Android `FirebaseMessagingService`）に渡して端末側で復号する。リレーが秘密鍵を持たない設計のため、将来の外部ユーザー向け有償提供時も E2E 前提を維持できる。

## テスト

```bash
bundle exec rake test
bundle exec rubocop
```

実 APNs / FCM / WNS に繋がず、送信クライアントの分岐だけを検証する minitest。
テスト用の gem は `development` グループにあり、flauros は `BUNDLE_WITHOUT=development`
なので本番には入らない。

## ブランチ

| ブランチ | デプロイ先 |
| --- | --- |
| `develop` | triton（ステージング） |
| `main` | flauros（本番）。⚠ **PR 必須・直 push 不可** |

詳細は[開発ガイドの「ブランチ運用」](docs/CLAUDE.md)。

## デプロイ

⚠ **ステージングを先に、本番を後に。**ホストごとに見るブランチが違うので、**ホストごとに丸ごと 1 ブロック**で回す。

```bash
# 1. ステージング（triton・develop を追う）
ssh deploy@triton.b-shock.local '
  cd ~/repos/capsicum-relay &&
  git pull &&
  bundle install &&
  sudo -n systemctl restart capsicum-relay
'
```

```bash
# 2. 本番（flauros・main を追う）。⚠ 1 の疎通確認が通ってから
ssh deploy@flauros.b-shock.co.jp '
  cd ~/repos/capsicum-relay &&
  git pull &&
  bundle install &&
  sudo -n systemctl restart capsicum-relay
'
```

⚠⚠ **`ssh` を 2 行並べてから共通のコマンドを書かない。**最初の `ssh` が triton のシェルを開いてしまい、**残りのコマンドがそちらで動く**（＝本番にしか当たらず、ステージングが未デプロイのまま「両方やった」ことになる）。ステージング先の手順そのものが壊れる形なので、**ホストごとに完結させる。**

疎通確認：

```bash
curl https://relay.capsicum.shrieker.net/health
# => {"status":"ok","subscriptions":N}
```

## ドキュメント

- [開発ガイド](docs/CLAUDE.md) — 設計方針・エンドポイント仕様・ペイロードスキーマ・インフラ構成・リリース計画
