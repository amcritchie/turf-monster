class ApplicationMailer < ActionMailer::Base
  TRANSACTIONAL_FROM = "Turf Monster <team@turfmonster.media>"
  MARKETING_FROM = "Alex from Turf Monster <alex@turfmonster.media>"
  RESEND_FROM = "McRitchie Studio <team@mcritchie.studio>"

  default from: -> { Studio.mailer_from || Studio.mailer_from_for_transport(ses_from: TRANSACTIONAL_FROM, resend_from: RESEND_FROM) }
  layout "mailer"

  private

  def marketing_from
    Studio.marketing_from_for_transport(ses_from: MARKETING_FROM, resend_from: RESEND_FROM)
  end

  # Absolute URL for a branded email banner, served from the app's OWN asset
  # pipeline (app/assets/images/emails/*.png) — no external bucket, version-
  # controlled with the code. The host comes from action_mailer.asset_host (set
  # per env: turfmonster.media in prod, localhost in dev); falls back to the
  # mailer's default_url_options host. Hosted (not a CID attachment) so it
  # renders in the inbox AND the admin email-manager preview.
  def email_banner_url(filename)
    path = ActionController::Base.helpers.asset_path("emails/#{filename}")
    return path if path.start_with?("http") # asset_host already absolute

    host = Rails.application.config.action_mailer.asset_host.presence
    host ||= begin
      h = default_url_options[:host]
      h && (h.start_with?("http") ? h : "https://#{h}")
    end
    "#{host}#{path}"
  end
end
