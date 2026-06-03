require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "login page renders" do
    get login_path
    assert_response :success
  end

  # A guest still sees the form (the redirect guard is for authed viewers only).
  test "guest GETting /login sees the form" do
    get login_path
    assert_response :success
    assert_nil session[Studio.session_key]
  end

  # An already-logged-in viewer hitting /login is bounced to their account
  # instead of being shown a dead-end "Sign in to play" form.
  test "authenticated user GETting /login is redirected to account" do
    log_in_as users(:alex)
    get login_path
    assert_redirected_to account_path
  end

  # A relative ?return_to is honoured; the form-render guard reuses the login
  # flow's redirect key so a deep-linked authed user lands where they intended.
  test "authenticated user GETting /login honours a relative return_to" do
    log_in_as users(:alex)
    get login_path(return_to: "/contests")
    assert_redirected_to "/contests"
  end

  # An absolute/protocol-relative return_to is ignored (open-redirect guard).
  test "authenticated user GETting /login ignores an off-site return_to" do
    log_in_as users(:alex)
    get login_path(return_to: "//evil.example.com")
    assert_redirected_to account_path
  end

  # Passwordless: log_in_as goes through the magic-link consume, which lands
  # an existing email user on root_path.
  test "login via magic link establishes a session" do
    log_in_as users(:alex)
    assert_redirected_to root_path
    follow_redirect!
    follow_redirect!
    assert_response :success
    assert_equal users(:alex).id, session[Studio.session_key]
  end

  # /login no longer authenticates a password — any POST is bounced to /login
  # with a magic-link hint. This is the core of Lazarus audit #4: there is no
  # password path to attack.
  test "create does NOT log in via password — bounces to magic link" do
    post login_path, params: { email: "alex@mcritchie.studio", password: "password" }
    assert_redirected_to login_path
    assert_nil session[Studio.session_key], "a password POST must NOT establish a session"
    follow_redirect!
    assert_match(/magic link/i, flash[:alert].to_s)
  end

  test "create with no params still just bounces" do
    post login_path
    assert_redirected_to login_path
    assert_nil session[Studio.session_key]
  end

  test "logout clears session" do
    log_in_as users(:alex)
    get logout_path
    assert_redirected_to login_path
    assert_nil session[Studio.session_key]
  end
end
