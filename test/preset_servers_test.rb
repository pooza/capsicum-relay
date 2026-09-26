require_relative 'test_helper'
require 'relay/preset_servers'

# プリセットサーバーの判定 (capsicum#597 / #59)。
#
# ⚠⚠ **ズレたときに壊れる向き**を固定する。この一覧に載っていないプリセット
# サーバーの利用者は「非プリセット」として数えられ、フェーズ 3 でゲートを
# 閉じたときに止まる。
class PresetServersTest < Minitest::Test
  def test_known_preset_host
    assert(Relay::PresetServers.preset?('mstdn.b-shock.org'))
    assert(Relay::PresetServers.preset?('misskey.delmulin.com'))
  end

  # ⚠ ステージングも含める（検証端末でゲートが閉じないように）。
  def test_staging_hosts_are_preset
    assert(Relay::PresetServers.preset?('st2.mstdn.b-shock.org'))
    assert(Relay::PresetServers.preset?('st3.mstdn.delmulin.com'))
  end

  def test_unknown_host
    refute(Relay::PresetServers.preset?('mastodon.social'))
  end

  # ⚠⚠ サブドメインを含めると他人のホストが通る。
  def test_subdomain_of_preset_is_not_preset
    refute(Relay::PresetServers.preset?('evil.mstdn.b-shock.org'))
    refute(Relay::PresetServers.preset?('mstdn.b-shock.org.evil.test'))
  end

  # ⚠ 大小と末尾のドットを揃えないと非プリセット扱いになる。
  def test_normalizes_case_and_trailing_dot
    assert(Relay::PresetServers.preset?('Mstdn.B-Shock.org'))
    assert(Relay::PresetServers.preset?('mstdn.b-shock.org.'))
    assert(Relay::PresetServers.preset?('  mstdn.b-shock.org  '))
  end

  def test_blank_is_not_preset
    refute(Relay::PresetServers.preset?(nil))
    refute(Relay::PresetServers.preset?(''))
    refute(Relay::PresetServers.preset?('   '))
  end

  def test_extra_hosts_are_additive
    assert(Relay::PresetServers.preset?('extra.test', extra: ['extra.test']))
    refute(Relay::PresetServers.preset?('extra.test'))
  end

  # ⚠⚠ **置き換えにしない。**設定を書き忘れたデプロイで全登録が非プリセット扱いに
  # なると、フェーズ 3 では全員のゲートが閉じる。
  def test_extra_hosts_cannot_remove_builtin
    assert(Relay::PresetServers.preset?('mstdn.b-shock.org', extra: []))
    assert(Relay::PresetServers.preset?('mstdn.b-shock.org', extra: nil))
    assert(Relay::PresetServers.preset?('mstdn.b-shock.org', extra: ['other.test']))
  end

  def test_extra_hosts_are_normalized_too
    assert(Relay::PresetServers.preset?('extra.test', extra: ['Extra.Test.']))
  end

  # ⚠ capsicum 側の一覧（`preset_servers.dart`）と件数を揃えてある。片方だけ
  # 増えたときに、ここが落ちて「写しがズレた」と分かるようにする。
  def test_host_count_is_pinned
    assert_equal(
      9,
      Relay::PresetServers::HOSTS.size,
      'capsicum の preset_servers.dart と件数が食い違っている。両方を見ること',
    )
  end
end
