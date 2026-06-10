# Single source of truth for the active fiat payment provider.
#
# The operator picks the provider via PAYMENT_PROVIDER (resolved at boot by
# config/initializers/paypal.rb into config.x.payment_provider — tests toggle
# that config the same way tokens_controller_test toggles x.stripe_enabled):
#   "stripe" — Stripe card checkout (the default when unset, so deploying the
#              PayPal branch changes nothing until the flag flips)
#   "paypal" — PayPal / Venmo buttons (Orders v2)
#   "none"   — no fiat onramp (token purchases hidden)
module Payments
  PROVIDERS = %w[stripe paypal none].freeze

  def self.provider
    configured = Rails.application.config.x.payment_provider
    configured.presence || "stripe"
  end

  def self.stripe?
    provider == "stripe"
  end

  def self.paypal?
    provider == "paypal"
  end

  def self.none?
    provider == "none"
  end
end
