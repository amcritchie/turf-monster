require "test_helper"
require "minitest/mock"

# The magic-link email banner is now admin-managed (Studio::EmailImage) with the
# versioned asset as the fallback, and the manager is reachable from the admin hub.
class EmailBannerTest < ActionDispatch::IntegrationTest
  test "magic-link email falls back to the static banner when none is managed" do
    mail = UserMailer.magic_link("x@example.com", magic_token(email: "x@example.com"))
    html = (mail.html_part&.body || mail.body).to_s
    assert_includes html, "magic-link-banner", "should fall back to the versioned asset banner"
  end

  test "magic-link email uses the admin-managed banner once uploaded" do
    Studio::S3.stub(:upload, ->(**_) { "https://bucket.s3.amazonaws.com/x" }) do
      Studio::S3.stub(:delete, ->(**_) { nil }) do
        Studio::EmailImage.store(:magic_link, io: StringIO.new("fake-png-bytes"), content_type: "image/png")
      end
    end
    record = Studio::EmailImage.record(:magic_link)
    assert record.present?

    mail = UserMailer.magic_link("x@example.com", magic_token(email: "x@example.com"))
    html = (mail.html_part&.body || mail.body).to_s
    assert_includes html, record.s3_key, "managed banner should win over the static fallback"
  end

  test "the email-images admin page is reachable by an admin" do
    log_in_as(users(:alex))
    get admin_email_images_path
    assert_response :success
    assert_select "h2", text: "Magic-link sign-in"
  end
end
