class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAILER_FROM", "alex@turfmonster.media")
  layout "mailer"
end
