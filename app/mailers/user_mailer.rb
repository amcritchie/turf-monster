class UserMailer < ApplicationMailer
  # OPSEC-005: email verification challenge. Token is a signed payload
  # (id + email + expiry) generated via Rails.application.message_verifier.
  # The recipient clicks the link → controller verifies the token → sets
  # users.email_verified_at. Tokens are scoped to the email they were
  # issued for; if the user changes email before verifying, the old token
  # no longer verifies.
  def email_verification(user, token)
    @user = user
    @verify_url = email_verifications_verify_url(token: token)
    mail(to: user.email, subject: "Verify your Turf Monster email")
  end
end
