class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAILER_FROM", "alex@turfmonster.media")
  layout "mailer"

  private

  # Public S3 URL for a branded email banner (uploaded under the bucket's
  # "email/" prefix). Hosted (not a CID attachment) so it renders both in the
  # inbox and in the admin email-manager preview.
  def email_banner_url(filename)
    Studio::S3.url(key: "email/#{filename}")
  end
end
