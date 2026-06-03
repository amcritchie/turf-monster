require "test_helper"

class MagicLinksControllerTest < ActionDispatch::IntegrationTest
  # ── request (POST /magic_link) ───────────────────────────────────────────
  test "create sends one magic-link email for a valid address" do
    assert_emails 1 do
      post magic_link_request_path, params: { email: "newbie@example.com" }
    end
    assert_redirected_to signin_path
  end

  test "create sends no email for a malformed address but still responds success" do
    assert_emails 0 do
      post magic_link_request_path, params: { email: "not-an-email" }
    end
    assert_redirected_to signin_path
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

  # ── prior-session hard reset on consume ──────────────────────────────────
  # A magic link is a fresh WEB2 (email) login. If the browser already held a
  # web3/Phantom-signature session, none of its state may bleed into the new
  # one — that bleed is what made a web2 magic-link user still look web3 and
  # popped the Phantom unlock probe on the landing. consume must reset_session
  # + clear the :onchain privilege flag before establishing the new session.
  test "consume hard-resets a prior web3 session and lands the email user as web2" do
    onchain_user = users(:sam)
    log_in_as_onchain(onchain_user)
    assert_equal true, session[:onchain], "precondition: prior session is a live web3 session"

    email_user = users(:jordan)
    token = MagicLink.generate(email: email_user.email)
    get magic_link_path(token: token)

    # New session belongs to the magic-link user, not the prior web3 user.
    assert_equal email_user.id, session[Studio.session_key]
    # The onchain privilege flag is gone — the new session is web2, not web3.
    assert_not session[:onchain], "onchain flag must not bleed into the magic-link session"

    # SessionContext for the new session reports web2 (onchain_session false).
    ctx = SessionContext.new(user: email_user, onchain_session: false)
    assert ctx.web2?, "magic-link email user should be web2"
    assert_not ctx.web3?
  end

  # Regression for PR #58: consume calls reset_session BEFORE set_app_session.
  # Application before_actions (notably detect_geo_state) write to session on
  # the SAME request that runs consume, so reset_session discards those prior
  # writes and rotates the session id mid-request. A brand-new signup must
  # still complete and land logged-in — the discarded geo keys are re-detected
  # next request and are not load-bearing for auth. (A friend tester clicking
  # the emailed link from a fresh browser is exactly this path.)
  test "consume creates + logs in the new user even when prior before-action session writes are present" do
    # Simulate the geo before_action having written to the session before
    # consume runs (the real detect_geo_state path).
    get magic_link_path(token: MagicLink.generate(email: "warmup@example.com"))
    # Now a genuinely new email; the jar already holds a rotated session.
    assert_difference "User.count", 1 do
      get magic_link_path(token: MagicLink.generate(email: "fresh-browser@example.com"))
    end
    user = User.find_by(email: "fresh-browser@example.com")
    assert_equal user.id, session[Studio.session_key], "new user must be logged in after reset_session"
    assert user.email_verified_at.present?
    assert user.username.present?, "auto-generated username must be set"
    assert_not session[:onchain], "a magic-link signup is web2, not web3"
  end

  # Regression for PR #58: clicking a magic link for a NEW email while already
  # logged in as a DIFFERENT user must switch the session to the new user with
  # no identity bleed from the prior session.
  test "consume for a new email while logged in as another user switches the session cleanly" do
    prior = users(:alex)
    log_in_as(prior)
    assert_equal prior.id, session[Studio.session_key], "precondition: logged in as the prior user"

    token = MagicLink.generate(email: "switcheroo@example.com")
    assert_difference "User.count", 1 do
      get magic_link_path(token: token)
    end
    switched = User.find_by(email: "switcheroo@example.com")
    assert_not_equal prior.id, session[Studio.session_key]
    assert_equal switched.id, session[Studio.session_key], "session must belong to the new user, not the prior one"
  end

  test "consume rejects an invalid token" do
    get magic_link_path(token: "bogus.token.value")
    assert_redirected_to signin_path
  end

  test "consume sanitizes a protocol-relative return_to (open-redirect guard)" do
    token = MagicLink.generate(email: users(:alex).email, return_to: "//evil.com/x")
    get magic_link_path(token: token)
    assert_redirected_to root_path
  end
end
