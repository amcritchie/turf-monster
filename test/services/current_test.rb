require "test_helper"

# Verifies that Current.user and Current.outbound_source flow into
# OutboundRequest rows when set before record!.
class CurrentTest < ActiveSupport::TestCase
  setup do
    @user = users(:alex)
    @purchase = StripePurchase.create!(
      user: @user, stripe_session_id: "cs_current_#{SecureRandom.hex(4)}",
      quantity: 1, price_cents: 19_00, status: "pending"
    )
  end

  teardown { Current.reset }

  test "Current.user attributes to OutboundRequest.user_id" do
    Current.user = @user
    OutboundRequestLogger.record!(service: "stripe", method: "POST", endpoint: "/v1/test")
    assert_equal @user.id, OutboundRequest.last.user_id
  end

  test "Current.outbound_source attributes to OutboundRequest source" do
    Current.outbound_source = @purchase
    OutboundRequestLogger.record!(service: "solana_rpc", method: "sendTransaction", endpoint: "https://x")
    rec = OutboundRequest.last
    assert_equal "StripePurchase", rec.source_type
    assert_equal @purchase.id,     rec.source_id
  end

  test "explicit arg wins over Current" do
    Current.user = @user
    other = users(:jordan)
    OutboundRequestLogger.record!(service: "stripe", user: other)
    assert_equal other.id, OutboundRequest.last.user_id
  end
end
