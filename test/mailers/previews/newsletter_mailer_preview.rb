# Preview at /rails/mailers/newsletter_mailer/welcome
class NewsletterMailerPreview < ActionMailer::Preview
  def welcome
    user = User.where.not(email: nil).first ||
           User.new(email: "you@example.com", username: "turf-fan")
    NewsletterMailer.welcome(user)
  end
end
