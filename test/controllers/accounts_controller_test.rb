require "test_helper"
require "minitest/mock"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alex = users(:alex)
  end

  test "show requires login" do
    get account_path
    assert_redirected_to login_path
  end

  test "save_profile saves and redirects to root" do
    log_in_as @alex
    post save_profile_account_path, params: { user: { name: "ignored" } }
    assert_redirected_to root_path
  end

  # --- session_state tests ---

  test "session_state returns guest shape for unauthenticated callers" do
    get session_state_account_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "guest", body["mode"]
    assert_equal false, body["loggedIn"]
    assert_nil body["userId"]
    assert_equal "", body["address"]
    assert body["csrf"].present?, "expected a fresh CSRF token in the response"
  end

  test "session_state carries usdcCents / usdtCents / tokensAvailable for guests" do
    # The synchronous entry-eligibility check (window.eligibilityBlocker)
    # reads these three fields off $store.session and assumes they exist.
    # Guests have no wallet at all — emit definitive 0s, not the null
    # "preload flaked" signal that only applies to logged-in users.
    get session_state_account_path, as: :json
    body = JSON.parse(response.body)
    assert_equal 0, body["usdcCents"]
    assert_equal 0, body["usdtCents"]
    assert_equal 0, body["tokensAvailable"]
  end

  test "client_session_payload converts uiAmount dollars to integer cents" do
    # Direct check of the conversion math — uses an inline controller subclass
    # so we can inject @wallet_balances without going through the RPC preload.
    user = @alex
    user.instance_variable_set(:@entry_token_balance, 4)
    ctl = ApplicationController.new
    ctl.instance_variable_set(:@wallet_balances, { usdc: 12.34, usdt: 0.5, sol: 1.0 })
    ctl.define_singleton_method(:current_user)     { user }
    ctl.define_singleton_method(:onchain_session?) { false }

    payload = ctl.send(:client_session_payload)
    assert_equal 1234, payload[:usdcCents],
                 "12.34 USDC should round to 1234 cents"
    assert_equal 50,   payload[:usdtCents],
                 "0.5 USDT should round to 50 cents"
    assert_equal 4,    payload[:tokensAvailable]
    # SessionContext identity fields still present.
    assert_equal user.id, payload[:userId]
    assert payload[:loggedIn]
  end

  test "session_state emits null usdcCents/usdtCents when preload nil'd (flake signal)" do
    # When the navbar preload's balances_thread silently nils (RPC flake —
    # see ApplicationController#perform_solana_preload), client_session_payload
    # emits null for usdcCents / usdtCents so the client can recognise
    # "unknown" and fail open in the eligibility check. tokensAvailable
    # still emits an integer because the token thread defaults to 0 on
    # error, accepting a temporary mis-read in exchange for type stability.
    log_in_as @alex
    get session_state_account_path, as: :json
    body = JSON.parse(response.body)
    assert body.key?("usdcCents"),       "expected usdcCents key in payload"
    assert body.key?("usdtCents"),       "expected usdtCents key in payload"
    assert body.key?("tokensAvailable"), "expected tokensAvailable key in payload"
    # In the integration test the preload before_action does NOT run (this
    # is the JSON session_state endpoint, gated to HTML format) so
    # @wallet_balances is nil → null fields. Token balance defaults to 0.
    assert_nil body["usdcCents"], "expected null when @wallet_balances is nil"
    assert_nil body["usdtCents"], "expected null when @wallet_balances is nil"
    assert_kind_of Integer, body["tokensAvailable"]
  end

  test "session_state returns web2 shape for an email-logged-in user" do
    log_in_as @alex
    get session_state_account_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "web2", body["mode"]
    assert_equal true, body["loggedIn"]
    assert_equal @alex.id, body["userId"]
    assert body["csrf"].present?
  end

  test "session_state returns web3 shape after a Phantom login" do
    user = User.create!(email: "phantom@mcritchie.studio", password: "password")
    log_in_as_onchain(user)
    get session_state_account_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "web3", body["mode"]
    assert_equal true, body["loggedIn"]
    assert_equal user.id, body["userId"]
    assert_equal user.reload.web3_solana_address, body["address"]
  end

  test "session_state skips require_profile_completion gate" do
    user = User.create!(email: "incomplete@mcritchie.studio", password: "password")
    # User with no username would normally hit require_profile_completion and
    # get redirected; session_state must be reachable for the visibilitychange
    # rehydrate hook to work even mid-onboarding.
    user.update_column(:username, nil)
    log_in_as user
    get session_state_account_path, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["loggedIn"]
  end

  # --- update_username tests ---

  test "update_username rejects a taken username" do
    # Must satisfy can_change_username? (wallet + entered) to reach the
    # validation check; otherwise the gate intercepts first with 403.
    @alex.update_columns(web2_solana_address: "test_wallet_alex_111", contest_entered: true)
    log_in_as @alex
    post update_username_account_path, params: { username: users(:jordan).username }, as: :json
    assert_response :unprocessable_entity
    assert_not JSON.parse(response.body)["success"]
  end

  test "update_username (custodial) saves via a server-signed set_username" do
    user = User.create!(email: "renamer@mcritchie.studio", password: "password") # managed wallet
    user.update_columns(contest_entered: true) # satisfy the gate
    log_in_as user
    fake_vault = Object.new
    def fake_vault.set_username(*, **)
      { signature: "sig_test" }
    end
    Solana::Vault.stub :new, fake_vault do
      post update_username_account_path, params: { username: "renamed-fox" }, as: :json
    end
    assert_response :success
    assert_equal "renamed-fox", user.reload.username
  end

  test "update_username is gated until contest_entered" do
    user = User.create!(email: "gated@mcritchie.studio", password: "password") # managed wallet, contest_entered: false
    log_in_as user
    post update_username_account_path, params: { username: "new-name-here" }, as: :json
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_not body["success"]
    assert_match(/Enter a contest first/i, body["error"])
    assert_equal user.username, user.reload.username, "username should not have changed"
  end

  test "update_username rejects when no wallet (gate fail-closed)" do
    user = User.create!(email: "nowallet@mcritchie.studio", password: "password")
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil, contest_entered: true)
    log_in_as user
    post update_username_account_path, params: { username: "new-name" }, as: :json
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_match(/No wallet/i, body["error"])
  end

  test "show renders for logged in user" do
    log_in_as @alex
    get account_path
    assert_response :success
  end

  test "update changes name" do
    log_in_as @alex
    patch account_path, params: { user: { name: "New Name" } }
    assert_redirected_to account_path
    @alex.reload
    assert_equal "New Name", @alex.name
  end

  test "unlink_google clears provider and uid" do
    @alex.update!(provider: "google_oauth2", uid: "12345")
    log_in_as @alex
    post unlink_google_account_path
    assert_redirected_to account_path
    @alex.reload
    assert_nil @alex.provider
    assert_nil @alex.uid
  end

  test "change_password updates password" do
    log_in_as @alex
    post change_password_account_path, params: {
      current_password: "password",
      new_password: "newpassword",
      new_password_confirmation: "newpassword"
    }
    assert_redirected_to account_path
    @alex.reload
    assert @alex.authenticate("newpassword")
  end

  test "change_password fails with wrong current password" do
    log_in_as @alex
    post change_password_account_path, params: {
      current_password: "wrongpassword",
      new_password: "newpassword",
      new_password_confirmation: "newpassword"
    }
    assert_response :unprocessable_entity
  end

  # OPSEC-007: update_level route + action removed. Previously accepted
  # client-supplied seeds_total which trivially inflated user level. Level
  # is now read directly from on-chain seeds (cached navbar localStorage
  # is populated from the server's authoritative confirm_onchain_entry
  # response). No replacement test needed — there's no longer a write path.

  # OPSEC-045: password change rotates session_token, booting other sessions
  test "change_password rotates session_token (OPSEC-045)" do
    log_in_as @alex
    before = @alex.session_token
    assert before.present?

    post change_password_account_path, params: {
      current_password: "password",
      new_password: "newpassword",
      new_password_confirmation: "newpassword"
    }
    assert_redirected_to account_path
    @alex.reload
    assert @alex.session_token.present?
    assert_not_equal before, @alex.session_token
  end

  test "stale session_token boots the request (OPSEC-045)" do
    log_in_as @alex
    # Simulate a stale cookie: another session rotated the user's token
    # (e.g., the user just changed password from a different device).
    @alex.update_column(:session_token, SecureRandom.hex(32))

    get account_path
    assert_redirected_to login_path
  end

  # OPSEC-046: email change requires current password + clears verified_at
  test "email change requires current password (OPSEC-046)" do
    @alex.update!(email_verified_at: Time.current)
    log_in_as @alex
    assert_emails 0 do
      patch account_path, params: {
        user: { email: "newaddr@example.com" },
        current_password: "wrongpassword"
      }
    end
    assert_response :unprocessable_entity
    @alex.reload
    assert_not_equal "newaddr@example.com", @alex.email
    assert @alex.email_verified_at.present?, "verified_at should be unchanged"
  end

  test "email change with correct password resets verified_at + sends notification (OPSEC-046)" do
    @alex.update!(email_verified_at: Time.current)
    old_email = @alex.email
    log_in_as @alex
    assert_emails 1 do
      patch account_path, params: {
        user: { email: "newaddr@example.com" },
        current_password: "password"
      }
    end
    @alex.reload
    assert_equal "newaddr@example.com", @alex.email
    assert_nil @alex.email_verified_at
    notice = ActionMailer::Base.deliveries.last
    assert_equal [old_email], notice.to
    assert_match(/email was changed/i, notice.subject)
  end

  test "non-email update (name only) does not require current_password" do
    log_in_as @alex
    patch account_path, params: { user: { name: "Different Name" } }
    assert_redirected_to account_path
    @alex.reload
    assert_equal "Different Name", @alex.name
  end
end
