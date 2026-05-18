Stripe.api_key = ENV["STRIPE_SECRET_KEY"]

Rails.application.config.x.stripe_enabled = ENV["STRIPE_SECRET_KEY"].present?

unless Rails.application.config.x.stripe_enabled
  Rails.logger.warn "[stripe] STRIPE_SECRET_KEY not set — token-pack card checkout is disabled."
end
