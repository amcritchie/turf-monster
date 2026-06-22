require "test_helper"

# The /i/<token> referral cutover (Studio::Link, kind: referral) replacing the
# old /contests/<slug>?ref=<slug> share link. The app-owned InvitesController#show
# handles the dispatch; this proves it works through turf-monster's own routing,
# attribution cookie, and signup attribution.
class ReferralLinkTest < ActionDispatch::IntegrationTest
  test "a referral /i link credits the inviter (cookie) + redirects to its target, reusably" do
    inviter = users(:alex)
    target  = "/contests/#{contests(:one).slug}"
    link    = Studio::Link.referral_for(inviter, target: target)
    expected = inviter.slug.presence || link.token

    assert_equal "referral", link.kind
    get link_path(link.token) # /i/<token>
    assert_redirected_to target
    assert_equal expected, cookies[:reference]
    assert_nil link.reload.consumed_at, "referral links are reusable, never burned"
    assert_nil session[Studio.session_key], "a referral click signs nobody in"
  end

  test "a new user who signed up after clicking the referral is attributed to the inviter" do
    inviter = users(:alex)
    link    = Studio::Link.referral_for(inviter, target: "/")
    expected = inviter.slug.presence || link.token

    get link_path(link.token) # sets the attribution cookie

    token = magic_token(email: "invited-friend@example.com", age_attested: true)
    assert_difference "User.count", 1 do
      post magic_link_consume_path(token: token)
    end
    assert_equal expected, User.find_by(email: "invited-friend@example.com").reference
  end

  test "the share card renders a tokenized /i invite URL (not the old ?ref= link)" do
    log_in_as(users(:alex))
    get contest_path(contests(:one))
    assert_response :success
    assert_match %r{/i/[A-Za-z0-9_-]+}, response.body, "share card should show the /i/<token> invite URL"
    assert_no_match %r{/contests/[\w-]+\?ref=}, response.body, "the old /contests/<slug>?ref= share link should be gone"
  end

  # Security: /i is referral-ONLY. A magic-link token must NOT be consumable here
  # (that would create an account via the engine's gateless sign_up_new, bypassing
  # the legal-age attestation gate). It is rejected with no session + no signup.
  test "a magic-link token is rejected at /i (no second sign-in path)" do
    token = magic_token(email: "sneaky@example.com")
    assert_no_difference "User.count" do
      get link_path(token) # GET /i/<magic token>
    end
    assert_redirected_to root_path
    assert_nil session[Studio.session_key], "no session may be established via /i"
    assert_nil magic_link_for("sneaky@example.com")&.consumed_at, "the magic link must not be burned"
  end

  test "POST /i is not routable (no consume verb on the invite path)" do
    post "/i/anything"
    assert_response :not_found
  end
end
