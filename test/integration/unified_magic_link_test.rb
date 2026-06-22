require "test_helper"

# Magic-link sign-in via the UNIFIED /l/<token> (Studio::Link). turf's own
# Studio::LinksController#consume routes through the GATED MagicLinksController
# create-or-login (legal-age attestation, contest landing) — NOT the engine's
# gateless path. /magic_link/<token> stays a back-compat alias; old /l/<slug>
# marketing links 301 to /lp.
class UnifiedMagicLinkTest < ActionDispatch::IntegrationTest
  # Exercise the legal-age gate as designed (ON), like MagicLinksControllerTest.
  # The flag is parked off by default for the first contest (age_attestation_flag_test).
  setup    { ENV["ENABLE_AGE_ATTESTATION"] = "true" }
  teardown { ENV.delete("ENABLE_AGE_ATTESTATION") }

  test "GET /l/<magic-token> is the inert confirm interstitial (no consume, no sign-in)" do
    token = magic_token(email: users(:alex).email, age_attested: true)
    get link_path(token)
    assert_response :success
    assert_select "form[action=?][method=post]", link_consume_path(token: token)
    assert_nil session[Studio.session_key]
  end

  test "POST /l/<magic-token> signs an existing user in" do
    token = magic_token(email: users(:alex).email, age_attested: true)
    post link_consume_path(token: token)
    assert_equal users(:alex).id, session[Studio.session_key]
  end

  # The security property of the whole refactor: consuming at /l goes through
  # turf's GATED sign_up_new, so a brand-new account still requires attestation.
  test "consuming at /l for a new email WITHOUT attestation is refused (age gate enforced)" do
    token = magic_token(email: "underage-l@example.com") # age_attested defaults false
    assert_no_difference "User.count" do
      post link_consume_path(token: token)
    end
    assert_redirected_to signin_path
    assert_match(/legal age/i, flash[:alert])
    assert_nil session[Studio.session_key]
  end

  test "consuming at /l for a new email WITH attestation creates the account" do
    assert_difference "User.count", 1 do
      post link_consume_path(token: magic_token(email: "of-age-l@example.com", age_attested: true))
    end
    assert User.find_by(email: "of-age-l@example.com").present?
  end

  test "an expired magic link is rejected at /l consume" do
    token = magic_token(email: "expired-l@example.com", age_attested: true)
    travel(Studio.magic_link_ttl + 1.minute) do
      post link_consume_path(token: token)
    end
    assert_redirected_to signin_path
    assert_nil session[Studio.session_key]
  end

  test "/magic_link/<token> still consumes (back-compat alias)" do
    token = magic_token(email: users(:alex).email, age_attested: true)
    post magic_link_consume_path(token: token)
    assert_equal users(:alex).id, session[Studio.session_key]
  end

  test "old /l/<landing-slug> 301-redirects to /lp (back-compat)" do
    slug = landing_pages(:launch).slug
    get "/l/#{slug}"
    assert_response :moved_permanently
    assert_redirected_to landing_page_path(slug) # /lp/<slug>
  end
end
