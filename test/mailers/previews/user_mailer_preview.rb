# Preview the styled magic-link email in the browser (development only):
#   http://localhost:<port>/rails/mailers/user_mailer/magic_link
#   http://localhost:<port>/rails/mailers/user_mailer/magic_link_with_contest
class UserMailerPreview < ActionMailer::Preview
  # Plain sign-in (no contest context).
  def magic_link
    UserMailer.magic_link(sample_email, sample_token)
  end

  # Contest-aware variant (the "finish my entry" copy + button).
  def magic_link_with_contest
    contest = Contest.first || Contest.new(name: "World Cup 2026")
    UserMailer.magic_link(sample_email, sample_token, contest: contest)
  end

  private

  def sample_email
    "preview@example.com"
  end

  def sample_token
    "preview-token-not-a-real-magic-link"
  end
end
