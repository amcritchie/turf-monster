# Resend (transactional email) wiring.
#
# Used by UserMailer for OPSEC-005 email verification. Becomes the default
# ActionMailer delivery method when RESEND_API_KEY is set (production +
# any dev shell that pulled the env var via bin/ecosystem-build).
#
# Local dev WITHOUT RESEND_API_KEY → mails go to log; tests use :test
# delivery (in-memory ActionMailer::Base.deliveries) regardless.
#
# Resend is the DEFAULT transport and the revert target — it yields ONLY when
# SES is the explicitly-selected, credentialed transport (MAIL_TRANSPORT=ses;
# see ses.rb). This is NOT being removed: flipping MAIL_TRANSPORT back to resend
# (or unsetting it) restores Resend instantly.
#
# To verify a new sending domain in Resend's dashboard:
#   Settings → Domains → Add Domain → enter mcritchie.studio → publish
#   the SPF/DKIM/DMARC DNS records they show. Until verified, sends from
#   that domain are rejected by Resend with 422 "domain not verified."

ses_active = ENV["MAIL_TRANSPORT"] == "ses" &&
             ENV["SES_SMTP_USERNAME"].present? && ENV["SES_SMTP_PASSWORD"].present?

if ENV["RESEND_API_KEY"].present? && !ses_active && !Rails.env.test?
  require "resend"

  Resend.api_key = ENV["RESEND_API_KEY"]

  # The `resend` gem ships an ActionMailer delivery method named :resend
  # (registered automatically when the gem loads).
  Rails.application.config.action_mailer.delivery_method = :resend
end
