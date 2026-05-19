# OPSEC-005: email verification for password + wallet signups.
#
# Three actions:
#   - new     GET  /email_verification/new
#             Render a "you need to verify your email" page (post-signup or
#             post-email-change).
#   - create  POST /email_verification
#             Generate a fresh token + send the verification mail.
#   - verify  GET  /email_verification/:token
#             Consume the token; if valid, set users.email_verified_at = now
#             and redirect to /account with a success flash.
#
# Token is generated via Rails.application.message_verifier(VERIFY_TOKEN_KEY)
# with a 24h expiry. The payload includes user.id + the email it was issued
# for, so a user who changes their email before verifying invalidates the
# pending token. Throttling is intentionally not implemented at this layer —
# add rack-attack rules on `/email_verification` if/when abuse appears.
class EmailVerificationsController < ApplicationController
  VERIFY_TOKEN_KEY = "email_verification_v1"
  VERIFY_TOKEN_TTL = 24.hours

  skip_before_action :require_authentication, only: [:verify]

  def new
    @user = current_user
  end

  def create
    @user = current_user
    return redirect_to root_path, alert: "Email already verified." if @user.email_verified_at.present?
    return redirect_to account_path, alert: "No email on file." if @user.email.blank?

    token = Rails.application.message_verifier(VERIFY_TOKEN_KEY).generate(
      { user_id: @user.id, email: @user.email },
      expires_in: VERIFY_TOKEN_TTL
    )
    UserMailer.email_verification(@user, token).deliver_later

    redirect_to email_verifications_new_path, notice: "Verification email sent. Check your inbox."
  rescue StandardError => e
    Rails.logger.error("[EmailVerificationsController#create] #{e.class}: #{e.message}")
    redirect_to email_verifications_new_path, alert: "Could not send the verification email."
  end

  def verify
    payload = Rails.application.message_verifier(VERIFY_TOKEN_KEY).verify(params[:token]).with_indifferent_access
    user = User.find_by(id: payload[:user_id])
    raise "Unknown account" unless user
    # If the user's email changed after the token was minted, refuse the
    # verification — the token is bound to the original email.
    raise "Token issued for a different email" unless user.email.to_s.downcase == payload[:email].to_s.downcase

    user.update!(email_verified_at: Time.current) if user.email_verified_at.blank?

    if logged_in?
      redirect_to account_path, notice: "Email verified. Thanks!"
    else
      redirect_to login_path, notice: "Email verified. You can sign in now."
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    redirect_to root_path, alert: "Verification link is invalid or expired. Request a fresh one from your account page."
  rescue StandardError => e
    Rails.logger.error("[EmailVerificationsController#verify] #{e.class}: #{e.message}")
    redirect_to root_path, alert: "Verification failed: #{e.message}"
  end
end
