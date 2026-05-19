Stripe.api_key = ENV["STRIPE_SECRET_KEY"]

Rails.application.config.x.stripe_enabled = ENV["STRIPE_SECRET_KEY"].present?

# OPSEC-032: production boot must hold authoritative Stripe credentials.
# Refusing to boot is the right failure mode — a silently-started prod app
# that 500s on every webhook (or worse, accepts test-mode events as live)
# is the actual incident we're preventing.
if Rails.env.production?
  if ENV["STRIPE_SECRET_KEY"].blank?
    raise "STRIPE_SECRET_KEY required in production (OPSEC-032)"
  end
  unless ENV["STRIPE_SECRET_KEY"].start_with?("sk_live_")
    raise "STRIPE_SECRET_KEY must be a live key (sk_live_...) in production — got #{ENV['STRIPE_SECRET_KEY'][0, 8]}... (OPSEC-032)"
  end
  if ENV["STRIPE_WEBHOOK_SECRET"].blank?
    raise "STRIPE_WEBHOOK_SECRET required in production (OPSEC-032)"
  end
end

unless Rails.application.config.x.stripe_enabled
  Rails.logger.warn "[stripe] STRIPE_SECRET_KEY not set — token-pack card checkout is disabled."
end
