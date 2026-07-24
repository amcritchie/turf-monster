require "test_helper"

# onramp_rail_visible? gates each rail card in the Add Funds hub
# (modals/_onramp_hub): every rail shows locally (dev/test) so the hub is
# always exercisable, but in production each rail reveals only when its own
# backend flag is live. Flag manipulation mirrors payments_test.rb +
# app_flags_test.rb (config.x.payment_provider / .stripe_enabled /
# .paypal_enabled + ENABLE_CDP_RAMP); production is faked with the same
# Rails.env.stub the webhook controller tests use.
class OnrampHelperTest < ActionView::TestCase
  include OnrampHelper

  # --- dev/test: every rail visible regardless of backend flags ---

  test "all rails are visible outside production even with every flag off" do
    with_cdp_ramp(nil) do
      with_coinflow(nil) do
        with_aeropay(nil) do
          swap_provider("none") do
            swap_stripe_enabled(false) do
              %i[coinbase coinflow aeropay paypal venmo stripe].each do |rail|
                assert onramp_rail_visible?(rail), "#{rail} should be visible in test env"
              end
            end
          end
        end
      end
    end
  end

  # --- production: each rail gates on its own backend flag ---

  test "coinbase is gated on AppFlags.cdp_ramp? in production" do
    in_production do
      with_cdp_ramp("true") { assert onramp_rail_visible?(:coinbase) }
      with_cdp_ramp(nil)    { assert_not onramp_rail_visible?(:coinbase) }
    end
  end

  test "coinflow is gated on AppFlags.coinflow? in production" do
    in_production do
      with_coinflow("true") { assert onramp_rail_visible?(:coinflow) }
      with_coinflow(nil)    { assert_not onramp_rail_visible?(:coinflow) }
    end
  end

  test "aeropay is gated on AppFlags.aeropay? in production" do
    in_production do
      with_aeropay("true") { assert onramp_rail_visible?(:aeropay) }
      with_aeropay(nil)    { assert_not onramp_rail_visible?(:aeropay) }
    end
  end

  test "paypal and venmo are gated on Payments.paypal_checkout? in production" do
    in_production do
      swap_paypal_enabled(true) do
        swap_provider("paypal") do
          assert onramp_rail_visible?(:paypal)
          assert onramp_rail_visible?(:venmo)
        end
        swap_provider("stripe") do
          assert_not onramp_rail_visible?(:paypal)
          assert_not onramp_rail_visible?(:venmo)
        end
      end
      swap_paypal_enabled(false) do
        swap_provider("paypal") do
          assert_not onramp_rail_visible?(:paypal)
          assert_not onramp_rail_visible?(:venmo)
        end
      end
    end
  end

  test "stripe is gated on Payments.stripe? in production" do
    in_production do
      swap_provider("stripe") do
        swap_stripe_enabled(true)  { assert onramp_rail_visible?(:stripe) }
        swap_stripe_enabled(false) { assert_not onramp_rail_visible?(:stripe) }
      end
      swap_provider("paypal") do
        swap_stripe_enabled(true) { assert_not onramp_rail_visible?(:stripe) }
      end
    end
  end

  private

  def in_production(&block)
    Rails.env.stub(:production?, true, &block)
  end

  def with_cdp_ramp(value)
    original = ENV["ENABLE_CDP_RAMP"]
    value.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = original
  end

  def with_coinflow(value)
    original = ENV["ENABLE_COINFLOW"]
    value.nil? ? ENV.delete("ENABLE_COINFLOW") : ENV["ENABLE_COINFLOW"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_COINFLOW") : ENV["ENABLE_COINFLOW"] = original
  end

  def with_aeropay(value)
    original = ENV["ENABLE_AEROPAY"]
    value.nil? ? ENV.delete("ENABLE_AEROPAY") : ENV["ENABLE_AEROPAY"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_AEROPAY") : ENV["ENABLE_AEROPAY"] = original
  end

  def swap_provider(value)
    original = Rails.application.config.x.payment_provider
    Rails.application.config.x.payment_provider = value
    yield
  ensure
    Rails.application.config.x.payment_provider = original
  end

  def swap_stripe_enabled(value)
    original = Rails.application.config.x.stripe_enabled
    Rails.application.config.x.stripe_enabled = value
    yield
  ensure
    Rails.application.config.x.stripe_enabled = original
  end

  def swap_paypal_enabled(value)
    original = Rails.application.config.x.paypal_enabled
    Rails.application.config.x.paypal_enabled = value
    yield
  ensure
    Rails.application.config.x.paypal_enabled = original
  end
end
