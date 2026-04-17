# capsicum-relay 開発ガイド

## プロジェクト概要

capsicum（Mastodon / Misskey クライアント）向けのプッシュ通知リレーサーバー。
Mastodon / Misskey が送出する Web Push を受信し、APNs（iOS）/ FCM（Android）に変換して転送する。

- **技術スタック**: Ruby / Sinatra / Puma / SQLite
- **ホスティング**: Linode Nanode（Ubuntu 24.04 LTS）
- **リポジトリ**: https://github.com/pooza/capsicum-relay

## アーキテクチャ

```
Mastodon / Misskey  ──Web Push──▶  capsicum-relay  ──APNs/FCM──▶  capsicum (iOS/Android)
                                   (flauros)
```

### エンドポイント

| メソッド | パス | 認証 | 用途 |
|---------|------|------|------|
| GET | `/health` | なし | ヘルスチェック |
| POST | `/register` | X-Relay-Secret | デバイストークン登録（capsicum → リレー） |
| DELETE | `/register/:id` | X-Relay-Secret | 登録解除 |
| POST | `/push/:push_token` | なし | Web Push 受信（Mastodon / Misskey → リレー） |

### 設計方針

- **Web Push ペイロードは復号しない** — Base64 エンコードのまま APNs / FCM に転送。復号はクライアント（capsicum）側で行う
- **認証** — capsicum からの `/register` は shared secret で認証。`/push/:push_token` はトークンの推測困難性で保護
- **DB** — SQLite。起動時に自動マイグレーション（テーブル未存在なら作成）

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
| プロセス管理 | systemd (`capsicum-relay.service`) |
| リバースプロキシ | nginx（HTTPS 終端、Let's Encrypt 自動更新） |
| Puma | `127.0.0.1:9292`（nginx 背後） |

### デプロイ手順

```bash
ssh deploy@flauros.b-shock.co.jp
cd ~/repos/capsicum-relay
git pull
bundle install
sudo systemctl restart capsicum-relay
```

### 疎通確認

```bash
curl https://relay.capsicum.shrieker.net/health
# => {"status":"ok","subscriptions":0}
```

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
    capsicum-relay.service # systemd ユニットファイル
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

## 関連リポジトリ

| リポジトリ | 関係 |
|-----------|------|
| [capsicum](https://github.com/pooza/capsicum) | クライアント本体。リレーにデバイストークンを登録し、通知を受信する |
| [mulukhiya-toot-proxy](https://github.com/pooza/mulukhiya-toot-proxy) | モロヘイヤ。Ruby の運用知見の共有元 |

## 関連 Issue

- [capsicum#52](https://github.com/pooza/capsicum/issues/52) — プッシュ通知リレー（本体 Issue）
- [capsicum#314](https://github.com/pooza/capsicum/issues/314) — iOS APNs デバイストークン取得

## 段階的リリース計画

詳細は capsicum の [push-relay-plan.md](https://github.com/pooza/capsicum/blob/develop/docs/push-relay-plan.md) を参照。

- **Stage 1**: Mastodon プッシュ通知（プリセットサーバー向け）— capsicum v1.18
- **Stage 2**: Misskey プッシュ通知
- **Stage 3**: 外部ユーザー向け有償提供

## 現在の状態（2026-04-17）

- [x] リポジトリ作成・雛形実装
- [x] flauros デプロイ・systemd 登録
- [x] nginx + Let's Encrypt 証明書（自動更新有効）
- [x] `/health` 疎通確認済み
- [ ] APNs クレデンシャル配置・動作確認（#52 の一環）
- [ ] FCM セットアップ（#52 の一環）
- [ ] shared_secret の本番値設定（#52 の一環）
- [ ] capsicum との結合テスト（#52 + #314）
