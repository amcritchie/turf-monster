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
      # Drive the REAL transport: the legal-age attestation rides the OAuth
      # request phase as a query param (exactly what /auth/google_popup and
      # the /signin form emit); OmniAuth snapshots request.GET into
      # session["omniauth.params"], which the callback pops back out.
      get "/auth/google_oauth2?age_attestation=1"
      follow_redirect!
    end

    assert_redirected_to tokens_buy_path
    user = User.find_by(email: "googleuser@example.com")
    assert_equal user.id, session[:turf_user_id]
    assert user.age_attested_at.present?, "new Google signup must be stamped age-attested"
  end

  # ── legal-age attestation (underwriting compliance) ───────────────────────
  test "google callback REFUSES a brand-new signup without the legal-age attestation" do
    assert_no_difference "User.count" do
      get "/auth/google_oauth2/callback"
    end
    assert_redirected_to signin_path
    assert_match(/legal age/i, flash[:alert])
    assert_nil session[:turf_user_id]
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

    assert_redirected_to signin_path
    assert_nil session[:turf_user_id]
  end

  test "failure redirects to login" do
    get "/auth/failure"
    assert_redirected_to signin_path
  end

  # ── Feature 1: Google sign-in colliding with a wallet-secured account ──────

  test "google callback on a wallet account routes to the wallet-login view" do
    sam = users(:sam) # fixture: has a web3 wallet, email unverified
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "g-#{SecureRandom.hex(4)}",
      info: { email: sam.email, name: "Sam" }
    )

    assert_no_difference "User.count" do
      get "/auth/google_oauth2/callback"
    end

    assert_redirected_to link_wallet_path
    assert_nil session[:turf_user_id], "should not be logged in until the wallet login completes"

    follow_redirect!
    assert_response :success
    assert_select "h1", text: /Login with Your Wallet/
  end

  test "wallet login completes the stashed Google link" do
    sam = users(:sam)
    google_uid = "g-#{SecureRandom.hex(4)}"
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: google_uid,
      info: { email: sam.email, name: "Sam" }
    )
    get "/auth/google_oauth2/callback"
    assert_redirected_to link_wallet_path

    # A real wallet login consumes the stash and links Google (both factors proven).
    log_in_as_onchain(sam)

    sam.reload
    assert_equal "google_oauth2", sam.provider
    assert_equal google_uid, sam.uid
    assert_equal sam.id, session[:turf_user_id]
  end

  test "GET /login/wallet without a pending link redirects to login" do
    get link_wallet_path
    assert_redirected_to signin_path
  end
end
