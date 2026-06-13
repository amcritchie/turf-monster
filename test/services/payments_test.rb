require "test_helper"

class PaymentsTest < ActiveSupport::TestCase
  test "defaults to stripe when no provider configured" do
    swap_provider(nil) do
      assert_equal "stripe", Payments.provider
      # stripe? ANDs in config.x.stripe_enabled, which is resolved at boot from
      # ENV["STRIPE_SECRET_KEY"] (config/initializers/stripe.rb). Force it on so
      # this test exercises the provider-default logic regardless of whether the
      # ambient env has a Stripe key (it's set via .env locally but absent in CI).
      swap_stripe_enabled(true) { assert Payments.stripe? }
      refute Payments.paypal?
      refute Payments.none?
    end
  end

  test "paypal provider" do
    swap_provider("paypal") do
      assert Payments.paypal?
      refute Payments.stripe?
    end
  end

  test "none provider" do
    swap_provider("none") do
      assert Payments.none?
      refute Payments.stripe?
      refute Payments.paypal?
    end
  end

  test "paypal_checkout? requires the flag AND credentials" do
    swap_paypal_enabled(true) do
      swap_provider("paypal") { assert Payments.paypal_checkout? }
      swap_provider("stripe") { refute Payments.paypal_checkout? }
    end
    swap_paypal_enabled(false) do
      swap_provider("paypal") { refute Payments.paypal_checkout? }
    end
  end

  private

  def swap_paypal_enabled(value)
    original = Rails.application.config.x.paypal_enabled
    Rails.application.config.x.paypal_enabled = value
    yield
  ensure
    Rails.application.config.x.paypal_enabled = original
  end

  def swap_stripe_enabled(value)
    original = Rails.application.config.x.stripe_enabled
    Rails.application.config.x.stripe_enabled = value
    yield
  ensure
    Rails.application.config.x.stripe_enabled = original
  end

  def swap_provider(value)
    original = Rails.application.config.x.payment_provider
    Rails.application.config.x.payment_provider = value
    yield
  ensure
    Rails.application.config.x.payment_provider = original
  end
end
