require "test_helper"

# turf-monster's adoption of studio-engine's model-page protocol. The engine owns
# Studio::ModelsController + Studio::ModelPage (unit-tested there); this proves the
# CONSUMER integration — the safe models are registered, the admin-only engine
# route renders THIS app's records + console command, and the admin dashboard
# links to it. Payment/wallet/PII models are intentionally NOT registered (the
# engine dumps record.as_json — all columns).
class ModelPageAdoptionTest < ActionDispatch::IntegrationTest
  test "[integration] the safe turf models are registered; sensitive ones are not" do
    %w[entry contest game player].each do |key|
      assert Studio::ModelPage.registered?(key), "#{key} should be registered"
    end
    refute Studio::ModelPage.registered?("user"), "User must NOT be registered (encrypted key + session_token + PII)"
    refute Studio::ModelPage.registered?("paypal_purchase"), "PaypalPurchase excluded pending an as_json filter"
  end

  test "[integration] admin model page renders this app's Contest JSON and console command" do
    contest = contests(:one)
    log_in_as(users(:alex))

    get studio_model_path("contest", contest.slug)

    assert_response :success
    expected_cmd = %(Contest.find_by(slug: "#{contest.slug}"))
    assert_select "code", text: /#{Regexp.escape(expected_cmd)}/
    assert_select "button[data-copy-text=?]", expected_cmd
    assert_select "a[href=?]", studio_model_random_path("contest")
    assert_select "pre" do |nodes|
      assert_match %("slug": "#{contest.slug}"), nodes.first.text
    end
  end

  test "[integration] a non-admin is redirected away from the model page" do
    contest = contests(:one)
    log_in_as(users(:jordan))

    get studio_model_path("contest", contest.slug)

    assert_redirected_to root_path
  end

  test "[integration] the random route redirects to a real contest's model page" do
    contests(:one)
    log_in_as(users(:alex))

    get studio_model_random_path("contest")

    assert_response :redirect
    assert_match %r{/models/contest/.+}, @response.location
  end

  test "[integration] an unregistered model key is not found" do
    log_in_as(users(:alex))

    get "/models/user/whatever" # user is intentionally not registered

    assert_response :not_found
  end

  test "[integration] the admin dashboard links to the model inspector" do
    log_in_as(users(:alex))

    get admin_dashboard_path

    assert_response :success
    assert_select "a[href=?]", studio_model_random_path("contest"), text: /Model JSON/
  end
end
