require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  # These tests exercise the legal-age attestation gate as designed (ON).
  # The flag is parked off by default for the first contest; the off state
  # is covered in age_attestation_flag_test.rb.
  setup    { ENV["ENABLE_AGE_ATTESTATION"] = "true" }
  teardown { ENV.delete("ENABLE_AGE_ATTESTATION") }

  # Unified auth: GET /signup 301-redirects to the canonical /signin page. The
  # engine POST /signup (account-from-email) still hits this controller — see below.
  test "GET /signup redirects to the unified signin page" do
    get signup_path
    assert_redirected_to signin_path
  end

  # (The authed-user redirect guard lives on /signin, where GET /signup 301s to;
  # it's covered in sessions_controller_test. GET /signup itself just redirects.)

  # Passwordless: the engine POST /signup creates the account from email alone
  # (Studio.registration_params is [:email, :reference]). The primary email
  # signup surface is now the magic link; this path stays as a fallback.
  test "signup with valid info" do
    assert_difference "User.count", 1 do
      post signup_path, params: { user: { email: "new@mcritchie.studio" }, age_attestation: "1" }
    end
    # Signup auto-assigns a username; new signups land on the token upsell.
    assert_redirected_to tokens_buy_path
    user = User.find_by(email: "new@mcritchie.studio")
    assert user.username.present?, "signup should auto-assign a username"
    assert user.age_attested_at.present?, "signup must stamp the legal-age attestation"
    assert_equal user.id, session[:turf_user_id]
  end

  test "signup with a duplicate email fails" do
    existing = users(:alex)
    assert_no_difference "User.count" do
      post signup_path, params: { user: { email: existing.email }, age_attestation: "1" }
    end
    assert_response :unprocessable_entity
  end

  # ── legal-age attestation (underwriting compliance) ───────────────────────
  test "signup without the legal-age attestation is rejected" do
    assert_no_difference "User.count" do
      post signup_path, params: { user: { email: "minor-maybe@mcritchie.studio" } }
    end
    assert_response :unprocessable_entity
    assert_nil session[:turf_user_id]
  end
end
