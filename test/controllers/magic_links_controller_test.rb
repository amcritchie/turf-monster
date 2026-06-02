require "test_helper"

class MagicLinksControllerTest < ActionDispatch::IntegrationTest
  # ── request (POST /magic_link) ───────────────────────────────────────────
  test "create sends one magic-link email for a valid address" do
    assert_emails 1 do
      post magic_link_request_path, params: { email: "newbie@example.com" }
    end
    assert_redirected_to login_path
  end

  test "create sends no email for a malformed address but still responds success" do
    assert_emails 0 do
      post magic_link_request_path, params: { email: "not-an-email" }
    end
    assert_redirected_to login_path
  end

  test "create responds JSON success for the modal" do
    assert_emails 1 do
      post magic_link_request_path, params: { email: "modal@example.com" }, as: :json
    end
    assert_response :success
    assert JSON.parse(response.body)["success"]
  end

  # ── consume (GET /magic_link/:token) ─────────────────────────────────────
  # consume now redirects to the LANDING page (return_to, else root) and carries
  # the welcome SUCCESS MODAL via flash[:magic_link_welcome] = { message, next };
  # the modal auto-redirects to the entry-tokens upsell client-side. It does NOT
  # redirect straight to tokens_buy_path nor set a :notice toast anymore.
  test "consume creates a passwordless, email-verified account and shows the welcome modal" do
    token = MagicLink.generate(email: "brand-new@example.com")
    assert_difference "User.count", 1 do
      get magic_link_path(token: token)
    end
    user = User.find_by(email: "brand-new@example.com")
    assert user.email_verified_at.present?, "new user should be email-verified by clicking the link"
    # No contest return_to → lands on root, not straight on the tokens page.
    assert_redirected_to root_path
    assert_nil flash[:notice], "the welcome should be a modal, not a toast"
    welcome = flash[:magic_link_welcome]
    assert welcome.present?, "consume should set the welcome modal flash signal"
    assert_equal tokens_buy_path, welcome[:next] || welcome["next"]
    assert (welcome[:message] || welcome["message"]).present?
    # The welcome modal renders the new user's auto-generated username under
    # the title; it must be carried in the flash (layout JSON → modal props).
    assert_equal user.username, welcome[:username] || welcome["username"]
  end

  test "consume lands a new signup on the contest return_to with the welcome modal" do
    token = MagicLink.generate(email: "newpicker@example.com", return_to: "/contests/the-cup?picks=1,2,3")
    get magic_link_path(token: token)
    assert_redirected_to "/contests/the-cup?picks=1,2,3"
    welcome = flash[:magic_link_welcome]
    assert welcome.present?
    assert_equal tokens_buy_path, welcome[:next] || welcome["next"]
    assert (welcome[:username] || welcome["username"]).present?, "welcome carries the username"
  end

  test "consume logs in an existing user on a safe return_to with the welcome modal" do
    existing = users(:alex)
    token = MagicLink.generate(email: existing.email, return_to: "/account")
    assert_no_difference "User.count" do
      get magic_link_path(token: token)
    end
    assert_redirected_to "/account"
    assert_equal existing.id, session[Studio.session_key]
    assert_nil flash[:notice], "the welcome should be a modal, not a toast"
    welcome = flash[:magic_link_welcome]
    assert welcome.present?, "existing sign-in should also show the welcome modal"
    assert_equal tokens_buy_path, welcome[:next] || welcome["next"]
    assert_equal existing.username, welcome[:username] || welcome["username"]
  end

  test "consume verifies an existing but never-verified email" do
    existing = users(:alex)
    existing.update!(email_verified_at: nil)
    token = MagicLink.generate(email: existing.email)
    get magic_link_path(token: token)
    assert existing.reload.email_verified_at.present?
  end

  test "consume rejects an invalid token" do
    get magic_link_path(token: "bogus.token.value")
    assert_redirected_to login_path
  end

  test "consume sanitizes a protocol-relative return_to (open-redirect guard)" do
    token = MagicLink.generate(email: users(:alex).email, return_to: "//evil.com/x")
    get magic_link_path(token: token)
    assert_redirected_to root_path
  end
end
