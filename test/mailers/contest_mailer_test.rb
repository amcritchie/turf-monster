require "test_helper"

class ContestMailerTest < ActionMailer::TestCase
  # contest_url for assertions — built the same way the mailer does (the test
  # env's default_url_options host is www.example.com).
  def contest_url(contest)
    Rails.application.routes.url_helpers.contest_url(contest, host: "www.example.com")
  end

  setup do
    @contest = contests(:one)
    @user    = users(:alex)
    @entry   = entries(:one)
    @entry.update!(user: @user, status: "complete", rank: 1, payout_cents: 4500)
  end

  test "winnings renders with payout, rank, contest name, winner name, and link" do
    mail = ContestMailer.winnings(@entry)

    assert_equal [@user.email], mail.to
    assert_equal "🏆 You won $45.00 on Turf Monster!", mail.subject

    [mail.html_part, mail.text_part].each do |part|
      body = part.body.to_s
      assert_match "$45.00", body, "payout amount missing from #{part.content_type}"
      assert_match @contest.name, body, "contest name missing from #{part.content_type}"
      assert_match @user.display_name, body, "winner name missing from #{part.content_type}"
      assert_match contest_url(@contest), body, "contest link missing from #{part.content_type}"
    end

    assert_match "1st", mail.html_part.body.to_s, "rank missing from html body"
  end

  test "winnings formats cents to dollars correctly" do
    @entry.update!(payout_cents: 10000)
    mail = ContestMailer.winnings(@entry)

    assert_equal "🏆 You won $100.00 on Turf Monster!", mail.subject
    assert_match "$100.00", mail.html_part.body.to_s
  end
end
