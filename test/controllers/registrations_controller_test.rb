require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "signup page renders" do
    get signup_path
    assert_response :success
  end

  # Passwordless: the engine POST /signup creates the account from email alone
  # (Studio.registration_params is [:email, :reference]). The primary email
  # signup surface is now the magic link; this path stays as a fallback.
  test "signup with valid info" do
    assert_difference "User.count", 1 do
      post signup_path, params: { user: { email: "new@mcritchie.studio" } }
    end
    # Signup auto-assigns a username; new signups land on the token upsell.
    assert_redirected_to tokens_buy_path
    user = User.find_by(email: "new@mcritchie.studio")
    assert user.username.present?, "signup should auto-assign a username"
    assert_equal user.id, session[:turf_user_id]
  end

  test "signup with a duplicate email fails" do
    existing = users(:alex)
    assert_no_difference "User.count" do
      post signup_path, params: { user: { email: existing.email } }
    end
    assert_response :unprocessable_entity
  end
end
