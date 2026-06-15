require "test_helper"

class StripeInitializerTest < ActiveSupport::TestCase
  INITIALIZER = Rails.root.join("config", "initializers", "stripe.rb").to_s

  setup do
    @saved_enabled = Rails.application.config.x.stripe_enabled
    @saved_api_key = Stripe.api_key
  end

  teardown do
    Rails.application.config.x.stripe_enabled = @saved_enabled
    Stripe.api_key = @saved_api_key
  end

  test "production default provider boots without Stripe secrets" do
    load_initializer(
      production: true,
      env: no_stripe_env
    )

    refute Rails.application.config.x.stripe_enabled
  end

  test "production provider=stripe requires a secret key" do
    error = assert_raises(RuntimeError) do
      load_initializer(
        production: true,
        env: live_stripe_env.merge("STRIPE_SECRET_KEY" => nil)
      )
    end

    assert_match(/STRIPE_SECRET_KEY required/, error.message)
  end

  test "production provider=stripe requires a live key" do
    error = assert_raises(RuntimeError) do
      load_initializer(
        production: true,
        env: live_stripe_env.merge("STRIPE_SECRET_KEY" => "sk_test_x")
      )
    end

    assert_match(/must be a live key/, error.message)
  end

  test "production provider=stripe requires webhook secret" do
    error = assert_raises(RuntimeError) do
      load_initializer(
        production: true,
        env: live_stripe_env.merge("STRIPE_WEBHOOK_SECRET" => nil)
      )
    end

    assert_match(/STRIPE_WEBHOOK_SECRET required/, error.message)
  end

  test "production provider=stripe enables checkout with a live key and webhook secret" do
    load_initializer(production: true, env: live_stripe_env)

    assert Rails.application.config.x.stripe_enabled
  end

  private

  def no_stripe_env
    {
      "PAYMENT_PROVIDER" => nil,
      "STRIPE_SECRET_KEY" => nil,
      "STRIPE_WEBHOOK_SECRET" => nil,
      "STRIPE_CHECKOUT_DISABLED" => nil
    }
  end

  def live_stripe_env
    no_stripe_env.merge(
      "PAYMENT_PROVIDER" => "stripe",
      "STRIPE_SECRET_KEY" => "sk_live_123",
      "STRIPE_WEBHOOK_SECRET" => "whsec_123"
    )
  end

  def load_initializer(production:, env:)
    with_env(env) do
      if production
        Rails.env.stub(:production?, true) { load INITIALIZER }
      else
        load INITIALIZER
      end
    end
  end

  def with_env(overrides)
    saved = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
