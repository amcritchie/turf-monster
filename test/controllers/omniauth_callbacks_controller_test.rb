require "test_helper"

class OmniauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "112233",
      info: { email: "googleuser@example.com", name: "Google User" }
    )
  end

  test "google callback creates user and logs in" do
    assert_difference "User.count", 1 do
      get "/auth/google_oauth2/callback"
    end

    assert_redirected_to root_path
    assert_equal User.find_by(email: "googleuser@example.com").id, session[:turf_user_id]
  end

  test "google callback logs in existing user when email is verified (OPSEC-005)" do
    alex = users(:alex)
    alex.update!(email_verified_at: Time.current)  # precondition for silent linking
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "445566",
      info: { email: alex.email, name: "Alex" }
    )

    assert_no_difference "User.count" do
      get "/auth/google_oauth2/callback"
    end

    assert_redirected_to root_path
    assert_equal alex.id, session[:turf_user_id]
  end

  test "google callback refuses silent link to unverified existing user (OPSEC-005)" do
    alex = users(:alex)
    alex.update!(email_verified_at: nil)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "445566",
      info: { email: alex.email, name: "Alex" }
    )

    assert_no_difference "User.count" do
      get "/auth/google_oauth2/callback"
    end

    assert_redirected_to login_path
    assert_nil session[:turf_user_id]
  end

  test "failure redirects to login" do
    get "/auth/failure"
    assert_redirected_to login_path
  end
end
