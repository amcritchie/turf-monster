require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "login page renders" do
    get login_path
    assert_response :success
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
