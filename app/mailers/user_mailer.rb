class UserMailer < ApplicationMailer
  # OPSEC-005: email verification challenge. Token is a signed payload
  # (id + email + expiry) generated via Rails.application.message_verifier.
  # The recipient clicks the link → controller verifies the token → sets
  # users.email_verified_at. Tokens are scoped to the email they were
  # issued for; if the user changes email before verifying, the old token
  # no longer verifies.
  def email_verification(user, token, contest: nil)
    @user = user
    @contest = contest
    @verify_url = email_verifications_verify_url(token: token)
    mail(to: user.email, subject: "Verify your Turf Monster email")
  end

  # Self-custody wallet export (task #11). Token is a signed payload from
  # AccountsController#initiate_wallet_export, valid 30 min. The recipient
  # clicks the link to land on the reveal page (Stage 2 — WalletExportsController#show).
  def wallet_export(user, token)
    @user = user
    @export_url = url_for(controller: "wallet_exports", action: "show", token: token, only_path: false)
    @support_email = "alex@turfmonster.media"
    mail(to: user.email, subject: "Your Turf Monster wallet export link")
  end

  # OPSEC-046: notify the OLD email address when a user changes their email.
  # If the change wasn't authorized by the legit user, this gives them an
  # out-of-band channel to notice + take action before the attacker has time
  # to verify the new address.
  def email_change_notification(user, old_email, new_email)
    @user = user
    @old_email = old_email
    @new_email = new_email
    mail(to: old_email, subject: "Your Turf Monster email was changed")
  end
end
