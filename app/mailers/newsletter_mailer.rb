class NewsletterMailer < ApplicationMailer
  layout "branded_mailer"

  # Email type: TRANSACTIONAL (action-triggered, sent once on the user's first
  # newsletter subscription). Includes a manage-preferences link per best
  # practice. NOTE: the formal transactional/marketing typing + one-click
  # unsubscribe move into the shared studio-engine email framework (Phase 2);
  # for now the preferences link points at the account page.
  def welcome(user)
    @user        = user
    @account_url = account_url
    @cta_url     = root_url
    @banner_url  = email_banner_url("welcome-banner.png")
    @banner_alt  = "You're in! — Turf Monster newsletter"
    mail(to: user.email, subject: "Welcome to the Turf Monster newsletter 🐊")
  end
end
