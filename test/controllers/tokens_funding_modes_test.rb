require "test_helper"

# The auth modal's tokens-picker step + /tokens/buy switch funding modes on
# the provider flags: Stripe packs while Stripe is enabled (current prod,
# unchanged), the CDP Buy-USDC handoff when Stripe is off and ENABLE_CDP_RAMP
# is on, and an honest offline card when both are off.
class TokensFundingModesTest < ActionDispatch::IntegrationTest
  setup do
    @stripe_was = Rails.application.config.x.stripe_enabled
  end

  teardown do
    Rails.application.config.x.stripe_enabled = @stripe_was
  end

  def with_cdp_ramp(value = "true")
    original = ENV["ENABLE_CDP_RAMP"]
    value.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = original
  end

  test "picker offers the CDP Buy USDC handoff when stripe is off and the ramp is on" do
    Rails.application.config.x.stripe_enabled = false
    with_cdp_ramp do
      get contests_path
      assert_response :success
      assert_includes response.body, "Buy USDC with Coinbase"
      assert_includes response.body, "$store.modals.swap('cdp-ramp'"
    end
  end

  test "picker keeps the Stripe packs byte-for-byte while stripe is enabled" do
    Rails.application.config.x.stripe_enabled = true
    with_cdp_ramp do
      get contests_path
      assert_response :success
      assert_includes response.body, "tokens-waiting"
      refute_includes response.body, "Buy USDC with Coinbase"
    end
  end

  test "picker degrades to the offline card when both providers are off" do
    Rails.application.config.x.stripe_enabled = false
    with_cdp_ramp(nil) do
      get contests_path
      assert_response :success
      assert_includes response.body, "Purchases temporarily offline"
      refute_includes response.body, "Buy USDC with Coinbase"
    end
  end

  test "STRIPE_CHECKOUT_DISABLED flips stripe_enabled off without unsetting the key" do
    original_key = ENV["STRIPE_SECRET_KEY"]
    ENV["STRIPE_SECRET_KEY"] = "sk_test_x" if original_key.blank?
    ENV["STRIPE_CHECKOUT_DISABLED"] = "true"
    load Rails.root.join("config/initializers/stripe.rb")
    refute Rails.application.config.x.stripe_enabled
  ensure
    ENV.delete("STRIPE_CHECKOUT_DISABLED")
    original_key.blank? ? ENV.delete("STRIPE_SECRET_KEY") : ENV["STRIPE_SECRET_KEY"] = original_key
    load Rails.root.join("config/initializers/stripe.rb")
  end

  test "/tokens/buy swaps dead packs for the CDP card when stripe is off and the ramp is on" do
    Rails.application.config.x.stripe_enabled = false
    with_cdp_ramp do
      log_in_as users(:jordan)
      get tokens_buy_path
      assert_response :success
      assert_includes response.body, "Buy USDC with Coinbase"
    end
  end
end
