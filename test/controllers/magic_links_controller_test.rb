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
  test "consume creates a passwordless, email-verified account and lands on the tokens upsell" do
    token = MagicLink.generate(email: "brand-new@example.com")
    assert_difference "User.count", 1 do
      get magic_link_path(token: token)
    end
    user = User.find_by(email: "brand-new@example.com")
    assert user.email_verified_at.present?, "new user should be email-verified by clicking the link"
    assert_not user.has_password?, "magic-link user should have no password"
    assert_redirected_to tokens_buy_path
  end

  test "consume logs in an existing user and honors a safe return_to" do
    existing = users(:alex)
    token = MagicLink.generate(email: existing.email, return_to: "/account")
    assert_no_difference "User.count" do
      get magic_link_path(token: token)
    end
    assert_redirected_to "/account"
    assert_equal existing.id, session[Studio.session_key]
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
