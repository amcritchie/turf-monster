require "test_helper"

# Render-gating coverage for the Add Funds hub (modals/_onramp_hub) and its
# entry-point link in the Get Entry Tokens picker. Logic-level production
# gating per rail is covered in test/helpers/onramp_helper_test.rb; this
# asserts the wired markup actually reaches the page. Mirrors
# tokens_funding_modes_test.rb (forces the Stripe picker so the "More ways"
# link renders).
class OnrampHubTest < ActionDispatch::IntegrationTest
  setup do
    @stripe_was = Rails.application.config.x.stripe_enabled
    # Force the Stripe tokens picker, which carries the "More ways" link.
    Rails.application.config.x.stripe_enabled = true
  end

  teardown do
    Rails.application.config.x.stripe_enabled = @stripe_was
  end

  test "the Get Entry Tokens picker links into the onramp hub" do
    get contests_path
    assert_response :success
    assert_includes response.body, "More ways to add funds"
    assert_includes response.body, "$store.modals.swap('onramp-hub'"
  end

  test "the hub shows all four rails in the test environment" do
    get contests_path
    assert_response :success
    %w[coinbase paypal venmo stripe].each do |rail|
      assert_includes response.body, %(data-onramp-rail="#{rail}"),
                       "expected the #{rail} rail card to render in test env"
    end
    # Coinbase + Stripe are the wired rails; assert their exact swap targets.
    assert_includes response.body, "$store.modals.swap('cdp-ramp', { flow: 'buy', step: 'preflight' })"
    assert_includes response.body, "$store.modals.swap('auth', { step: 'tokens-picker'"
  end
end
