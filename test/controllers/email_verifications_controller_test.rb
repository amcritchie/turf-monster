require "test_helper"

class EmailVerificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alex = users(:alex)
    @alex.update!(email_verified_at: nil)
  end

  test "new renders for logged-in user" do
    log_in_as @alex
    get email_verifications_new_path
    assert_response :success
  end

  test "create sends verification email" do
    log_in_as @alex
    assert_emails 1 do
      post email_verifications_path
    end
    assert_redirected_to email_verifications_new_path
  end

  test "create refuses when email already verified" do
    @alex.update!(email_verified_at: Time.current)
    log_in_as @alex
    assert_emails 0 do
      post email_verifications_path
    end
    assert_redirected_to root_path
  end

  test "verify with valid token marks email verified" do
    token = Rails.application.message_verifier(EmailVerificationsController::VERIFY_TOKEN_KEY).generate(
      { user_id: @alex.id, email: @alex.email },
      expires_in: 24.hours
    )

    get email_verifications_verify_path(token: token)
    assert_redirected_to login_path
    assert @alex.reload.email_verified_at.present?
  end

  test "verify with invalid token refuses" do
    get email_verifications_verify_path(token: "bogus.token.value")
    assert_redirected_to root_path
    assert @alex.reload.email_verified_at.blank?
  end

  test "verify refuses if email changed after token issuance" do
    token = Rails.application.message_verifier(EmailVerificationsController::VERIFY_TOKEN_KEY).generate(
      { user_id: @alex.id, email: "old@example.com" },
      expires_in: 24.hours
    )

    get email_verifications_verify_path(token: token)
    assert_redirected_to root_path
    assert @alex.reload.email_verified_at.blank?
  end
end
