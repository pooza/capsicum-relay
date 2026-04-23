# capsicum-relay

[capsicum](https://github.com/pooza/capsicum)（Mastodon / Misskey クライアント）向けのプッシュ通知リレーサーバー。Mastodon / Misskey が送出する Web Push を受信し、APNs（iOS）/ FCM（Android）に変換して転送する。

Ruby / Sinatra / Puma / SQLite。Linode Nanode で運用中。`relay.capsicum.shrieker.net`。

## 仕組み

登録からプッシュ配信までの一連の流れは、[開発ガイドのシーケンス図](docs/CLAUDE.md#通信フロー) を参照。このリレーがやっていることは、その図がもっとも雄弁に語っている。

補足として、暗号化された Web Push ペイロードはリレーでは復号せず、Base64 のままクライアント（iOS NSE / Android `FirebaseMessagingService`）に渡して端末側で復号する。リレーが秘密鍵を持たない設計のため、将来の外部ユーザー向け有償提供時も E2E 前提を維持できる。

## デプロイ

```bash
ssh deploy@flauros.b-shock.co.jp
cd ~/repos/capsicum-relay
git pull
bundle install
sudo systemctl restart capsicum-relay
```

疎通確認：

```bash
curl https://relay.capsicum.shrieker.net/health
# => {"status":"ok","subscriptions":N}
```

## ドキュメント

- [開発ガイド](docs/CLAUDE.md) — 設計方針・エンドポイント仕様・ペイロードスキーマ・インフラ構成・リリース計画
