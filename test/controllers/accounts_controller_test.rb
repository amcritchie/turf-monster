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

  test "update_username rejects a taken username" do
    log_in_as @alex
    post update_username_account_path, params: { username: users(:jordan).username }, as: :json
    assert_response :unprocessable_entity
    assert_not JSON.parse(response.body)["success"]
  end

  test "update_username (custodial) saves via a server-signed set_username" do
    user = User.create!(email: "renamer@mcritchie.studio", password: "password") # managed wallet
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
