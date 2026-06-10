require "test_helper"

class PaymentsTest < ActiveSupport::TestCase
  test "defaults to stripe when no provider configured" do
    swap_provider(nil) do
      assert_equal "stripe", Payments.provider
      assert Payments.stripe?
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

  private

  def swap_provider(value)
    original = Rails.application.config.x.payment_provider
    Rails.application.config.x.payment_provider = value
    yield
  ensure
    Rails.application.config.x.payment_provider = original
  end
end
