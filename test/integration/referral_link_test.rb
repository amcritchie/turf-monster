require "test_helper"

# Referral invites via the UNIFIED /l/<token> entry point (Studio::Link, kind:
# referral). turf's own Studio::LinksController#show handles the dispatch: a
# referral sets the attribution cookie + redirects (reusable, GET-only). The old
# /i/<token> links 301 into /l for back-compat; the legacy ?ref= share link is gone.
class ReferralLinkTest < ActionDispatch::IntegrationTest
  test "a referral /l link credits the inviter (cookie) + redirects to its target, reusably" do
    inviter = users(:alex)
    target  = "/contests/#{contests(:one).slug}"
    link    = Studio::Link.referral_for(inviter, target: target)
    expected = inviter.slug.presence || link.token

    assert_equal "referral", link.kind
    get link_path(link.token) # GET /l/<token>
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
      post link_consume_path(token: token)
    end
    assert_equal expected, User.find_by(email: "invited-friend@example.com").reference
  end

  test "the share card renders a tokenized /l invite URL (not the old ?ref= link)" do
    log_in_as(users(:alex))
    get contest_path(contests(:one))
    assert_response :success
    assert_match %r{/l/[A-Za-z0-9_-]+}, response.body, "share card should show the /l/<token> invite URL"
    assert_no_match %r{/contests/[\w-]+\?ref=}, response.body, "the old /contests/<slug>?ref= share link should be gone"
  end

  test "old /i/<token> invite links 301-redirect to /l (back-compat)" do
    link = Studio::Link.referral_for(users(:alex), target: "/")
    get "/i/#{link.token}"
    assert_response :moved_permanently
    assert_redirected_to "/l/#{link.token}"
  end

  test "POSTing a referral token to /l consume is rejected (referral is GET-only)" do
    link = Studio::Link.referral_for(users(:alex), target: "/")
    post link_consume_path(token: link.token)
    assert_redirected_to signin_path
    assert_nil session[Studio.session_key]
    assert_nil link.reload.consumed_at, "a referral link must never be burned"
  end
end
