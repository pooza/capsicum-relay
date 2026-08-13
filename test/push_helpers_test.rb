require_relative 'test_helper'
require 'lib/relay/push_helpers'

# #27: App から切り出した push helper 群がモジュールとして揃っていることを固定
# する。App は config/settings.yml を読む configure ブロックがあり test から
# require できないため、mixin される側のモジュール契約をここで守る。
class PushHelpersTest < Minitest::Test
  EXPECTED_METHODS = [
    :build_push_payload, :dispatch_push, :push_client_for, :log_push_received,
    :handle_push_result, :push_context, :handle_push_delivered, :handle_wns_status,
    :handle_push_gone, :handle_push_oversized, :handle_push_degraded, :handle_push_failed
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
