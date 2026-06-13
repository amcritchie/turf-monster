# Amazon SES (SMTP) — outbound email transport, opt-in via MAIL_TRANSPORT=ses.
#
# Deliberately INERT by default: SES SMTP credentials can be staged on Heroku
# without touching the live path. The transport only switches to SES when
# MAIL_TRANSPORT=ses is set explicitly AND the creds are present. To revert to
# Resend at any time, unset MAIL_TRANSPORT (or set it to "resend") — Resend
# resumes (see resend.rb). Nothing here is destructive; the two transports are
# mutually exclusive on the same MAIL_TRANSPORT check.
#
# Cutover (after SES is out of sandbox + turfmonster.media is verified):
#   heroku config:set -a turf-monster-mainnet \
#     SES_SMTP_USERNAME=... SES_SMTP_PASSWORD=... SES_REGION=us-east-2
#   heroku config:set -a turf-monster-mainnet MAIL_TRANSPORT=ses   # the flip
# Revert:
#   heroku config:unset -a turf-monster-mainnet MAIL_TRANSPORT
#
# Health check: `bin/rails ses:check` (see lib/tasks/ses.rake).

ses_selected = ENV["MAIL_TRANSPORT"] == "ses"
ses_ready    = ses_selected && ENV["SES_SMTP_USERNAME"].present? && ENV["SES_SMTP_PASSWORD"].present?

if ses_selected && !ses_ready && !Rails.env.test?
  Rails.logger.warn "[mail] MAIL_TRANSPORT=ses but SES_SMTP_USERNAME/PASSWORD missing — keeping Resend"
end

if ses_ready && !Rails.env.test?
  region = ENV.fetch("SES_REGION", "us-east-2")
  ActionMailer::Base.delivery_method = :smtp
  ActionMailer::Base.smtp_settings = {
    address:              ENV.fetch("SES_SMTP_HOST", "email-smtp.#{region}.amazonaws.com"),
    port:                 ENV.fetch("SES_SMTP_PORT", 587).to_i,
    user_name:            ENV["SES_SMTP_USERNAME"],
    password:             ENV["SES_SMTP_PASSWORD"],
    authentication:       :login,
    enable_starttls_auto: true
  }
  Rails.logger.info "[mail] transport=SES region=#{region} from=#{ENV.fetch('MAILER_FROM', 'alex@turfmonster.media')}"
end
