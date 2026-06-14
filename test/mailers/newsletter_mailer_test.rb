require "test_helper"

class NewsletterMailerTest < ActionMailer::TestCase
  test "welcome greets by name, confirms the 25-seed reward, and links to email preferences" do
    user = User.create!(email: "sam@example.com")
    mail = NewsletterMailer.welcome(user)

    assert_equal ["sam@example.com"], mail.to
    assert_equal ["team@mcritchie.studio"], mail.from
    assert_includes mail[:from].to_s, "McRitchie Studio"
    assert_equal "Welcome to the Turf Monster newsletter 🐊", mail.subject

    body = mail.html_part.body.to_s
    assert_includes body, user.display_name, "greets the recipient by their display name"
    assert_includes body, "25 seeds"
    assert_match %r{/account}, body, "manage-preferences link points at the account page"
  end
end
