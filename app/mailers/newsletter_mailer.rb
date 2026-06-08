class NewsletterMailer < ApplicationMailer
  # Email type: TRANSACTIONAL (action-triggered, sent once on the user's first
  # newsletter subscription). Includes a manage-preferences link per best
  # practice. NOTE: the formal transactional/marketing typing + one-click
  # unsubscribe move into the shared studio-engine email framework (Phase 2);
  # for now the preferences link points at the account page.
  def welcome(user)
    @user        = user
    @account_url = account_url
    mail(to: user.email, subject: "Welcome to the Turf Monster newsletter 🐊")
  end
end
