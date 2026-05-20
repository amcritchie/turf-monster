require "test_helper"

# Funnel/campaign attribution: a `?reference=` URL param (or a landing page's
# slug) is captured first-touch into a cookie and written onto the user when
# the account is created.
class ReferenceAttributionTest < ActionDispatch::IntegrationTest
  test "a ?reference= param is captured into a cookie" do
    get faucet_path, params: { reference: "spring-campaign" }
    assert_equal "spring-campaign", cookies[:reference]
  end

  test "the reference cookie is first-touch and not overwritten" do
    get faucet_path, params: { reference: "first" }
    get faucet_path, params: { reference: "second" }
    assert_equal "first", cookies[:reference]
  end

  test "the signup page carries the reference in a hidden field" do
    get faucet_path, params: { reference: "friends-test" }
    get signup_path
    assert_select "input[type=hidden][name=?][value=?]", "user[reference]", "friends-test"
  end

  test "email signup persists the reference onto the new user" do
    assert_difference "User.count", 1 do
      post signup_path, params: {
        user: { email: "newbie@mcritchie.studio", password: "password",
                password_confirmation: "password", reference: "friends-test" }
      }
    end
    assert_equal "friends-test", User.find_by(email: "newbie@mcritchie.studio").reference
  end

  test "google signup persists the reference onto the new user" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "ref-9001",
      info: { email: "googlenewbie@example.com", name: "Google Newbie" }
    )
    get faucet_path, params: { reference: "friends-test" }
    assert_difference "User.count", 1 do
      get "/auth/google_oauth2/callback"
    end
    assert_equal "friends-test", User.find_by(email: "googlenewbie@example.com").reference
  end
end
