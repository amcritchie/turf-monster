require "test_helper"

# Boot-guard behavior of config/initializers/paypal.rb (OPSEC-032 parity):
# production with PAYMENT_PROVIDER=paypal must refuse to boot without live env
# + full credentials, and the guard must stay inert for every other provider
# value so this branch deploys with zero production impact until the operator
# flips the flag. Tests re-load the initializer file with scoped ENV.
class PaypalInitializerTest < ActiveSupport::TestCase
  INITIALIZER = Rails.root.join("config", "initializers", "paypal.rb").to_s

  FULL_LIVE_ENV = {
    "PAYMENT_PROVIDER" => "paypal",
    "PAYPAL_ENV" => "live",
    "PAYPAL_CLIENT_ID" => "cid",
    "PAYPAL_CLIENT_SECRET" => "sec",
    "PAYPAL_WEBHOOK_ID" => "wh"
  }.freeze

  NO_PAYPAL_ENV = {
    "PAYMENT_PROVIDER" => nil,
    "PAYPAL_ENV" => nil,
    "PAYPAL_CLIENT_ID" => nil,
    "PAYPAL_CLIENT_SECRET" => nil,
    "PAYPAL_WEBHOOK_ID" => nil
  }.freeze

  setup do
    @saved_provider = Rails.application.config.x.payment_provider
    @saved_enabled  = Rails.application.config.x.paypal_enabled
  end

  teardown do
    Rails.application.config.x.payment_provider = @saved_provider
    Rails.application.config.x.paypal_enabled   = @saved_enabled
  end

  test "production + provider=paypal refuses to boot unless PAYPAL_ENV is live" do
    error = assert_raises(RuntimeError) do
      load_initializer(production: true, env: FULL_LIVE_ENV.merge("PAYPAL_ENV" => "sandbox"))
    end
    assert_match(/PAYPAL_ENV must be "live"/, error.message)
  end

  test "production + provider=paypal refuses to boot when any credential is missing" do
    %w[PAYPAL_CLIENT_ID PAYPAL_CLIENT_SECRET PAYPAL_WEBHOOK_ID].each do |missing|
      error = assert_raises(RuntimeError, "expected a boot refusal when #{missing} is unset") do
        load_initializer(production: true, env: FULL_LIVE_ENV.merge(missing => nil))
      end
      assert_match(/#{missing} required in production/, error.message)
    end
  end

  test "production + provider=paypal boots with live env and full credentials" do
    load_initializer(production: true, env: FULL_LIVE_ENV)
    assert_equal "paypal", Rails.application.config.x.payment_provider
    assert Rails.application.config.x.paypal_enabled
  end

  test "production on the default provider ignores missing PayPal config entirely — deploy-inert" do
    load_initializer(production: true, env: NO_PAYPAL_ENV)
    assert_equal "none", Rails.application.config.x.payment_provider
    refute Rails.application.config.x.paypal_enabled
  end

  test "production with provider=none skips the guard too" do
    load_initializer(production: true, env: NO_PAYPAL_ENV.merge("PAYMENT_PROVIDER" => "none"))
    assert_equal "none", Rails.application.config.x.payment_provider
  end

  test "non-production sandbox paypal boots without a webhook id (sandbox-first)" do
    load_initializer(production: false, env: FULL_LIVE_ENV.merge("PAYPAL_ENV" => "sandbox", "PAYPAL_WEBHOOK_ID" => nil))
    assert_equal "paypal", Rails.application.config.x.payment_provider
    assert Rails.application.config.x.paypal_enabled
  end

  test "paypal_enabled requires BOTH client id and secret" do
    load_initializer(production: false, env: NO_PAYPAL_ENV.merge("PAYPAL_CLIENT_ID" => "cid"))
    refute Rails.application.config.x.paypal_enabled
  end

  test "provider value is normalized — trimmed and downcased" do
    load_initializer(production: false, env: NO_PAYPAL_ENV.merge("PAYMENT_PROVIDER" => "  PayPal "))
    assert_equal "paypal", Rails.application.config.x.payment_provider
  end

  private

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
