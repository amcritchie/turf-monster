require "test_helper"

class PaymentsTest < ActiveSupport::TestCase
  test "defaults to none when no provider configured" do
    swap_provider(nil) do
      assert_equal "none", Payments.provider
      swap_stripe_enabled(true) { refute Payments.stripe? }
      refute Payments.paypal?
      assert Payments.none?
    end
  end

  test "stripe provider requires stripe_enabled" do
    swap_provider("stripe") do
      swap_stripe_enabled(true) { assert Payments.stripe? }
      swap_stripe_enabled(false) { refute Payments.stripe? }
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
