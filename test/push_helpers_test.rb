require_relative 'test_helper'
require 'lib/relay/push_helpers'

# #27: App から切り出した push helper 群がモジュールとして揃っていることを固定
# する。App は config/settings.yml を読む configure ブロックがあり test から
# require できないため、mixin される側のモジュール契約をここで守る。
class PushHelpersTest < Minitest::Test
  # ⚠ **配送の結末を扱う helper は #55 でここから出た。**非同期になり、
  # `status` / `halt` という request scope の side effect と一体では worker から
  # 呼べなくなったため、[Relay::PushDeliveryReporter]（出力）と
  # [Relay::PushOutcome]（解釈）へ移した。ここに残るのは**受信の助け**だけ。
  EXPECTED_METHODS = [
    :build_push_payload, :push_client_for, :log_push_received,
    :push_received_fields, :push_received_message
  ].freeze

  def test_is_a_module_for_sinatra_helpers_mixin
    assert_kind_of(Module, Relay::PushHelpers)
    refute_kind_of(Class, Relay::PushHelpers)
  end

  def test_exposes_all_extracted_push_helpers
    EXPECTED_METHODS.each do |name|
      assert_includes(Relay::PushHelpers.instance_methods(false), name, "missing #{name}")
    end
  end

  # authenticate! / json_body は push 固有でなく全 route が使うので App に残す。
  def test_keeps_generic_helpers_in_app
    refute_includes(Relay::PushHelpers.instance_methods(false), :authenticate!)
    refute_includes(Relay::PushHelpers.instance_methods(false), :json_body)
  end

  def test_moves_wns_benign_statuses_constant
    assert_equal(['dropped'], Relay::PushHelpers::WNS_BENIGN_STATUSES)
  end
end
