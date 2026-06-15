Stripe.api_key = ENV["STRIPE_SECRET_KEY"]
stripe_provider = (ENV["PAYMENT_PROVIDER"].presence || "none").to_s.strip.downcase == "stripe"

# STRIPE_CHECKOUT_DISABLED is the checkout-only kill-switch: it hides the
# pack buttons and blocks new checkout sessions WITHOUT removing the API key
# — the key must stay set so webhooks, refunds, and dispute handling for
# past purchases keep working (and OPSEC-032 below keeps holding).
Rails.application.config.x.stripe_enabled =
  stripe_provider &&
  ENV["STRIPE_SECRET_KEY"].present? &&
  ENV["STRIPE_CHECKOUT_DISABLED"].to_s.strip.downcase != "true"

# OPSEC-032: production boot must hold authoritative Stripe credentials.
# Refusing to boot is the right failure mode — a silently-started prod app
# that 500s on every webhook (or worse, accepts test-mode events as live)
# is the actual incident we're preventing.
stripe_secret_present = ENV["STRIPE_SECRET_KEY"].present?
stripe_webhook_present = ENV["STRIPE_WEBHOOK_SECRET"].present?

if Rails.env.production? && (stripe_provider || stripe_secret_present || stripe_webhook_present)
  if ENV["STRIPE_SECRET_KEY"].blank?
    raise "STRIPE_SECRET_KEY required in production when Stripe is selected or Stripe secrets are present (OPSEC-032)"
  end
  unless ENV["STRIPE_SECRET_KEY"].start_with?("sk_live_")
    raise "STRIPE_SECRET_KEY must be a live key (sk_live_...) in production — got #{ENV['STRIPE_SECRET_KEY'][0, 8]}... (OPSEC-032)"
  end
  if stripe_provider && ENV["STRIPE_WEBHOOK_SECRET"].blank?
    raise "STRIPE_WEBHOOK_SECRET required in production when PAYMENT_PROVIDER=stripe (OPSEC-032)"
  end
end

if stripe_provider && !Rails.application.config.x.stripe_enabled
  Rails.logger.warn "[stripe] token-pack card checkout is disabled " \
    "(#{ENV['STRIPE_SECRET_KEY'].present? ? 'STRIPE_CHECKOUT_DISABLED' : 'STRIPE_SECRET_KEY not set'})."
end
