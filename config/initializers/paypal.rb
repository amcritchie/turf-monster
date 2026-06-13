# PayPal / Venmo onramp config + the active-fiat-provider flag.
#
# PAYMENT_PROVIDER resolution happens here (not in app/services/payments.rb)
# because initializers can't touch autoloaded constants; Payments reads the
# config.x value this sets. Default "stripe" — deploying this branch with no
# env changes leaves production behavior untouched.
provider = (ENV["PAYMENT_PROVIDER"].presence || "stripe").to_s.strip.downcase
Rails.application.config.x.payment_provider = provider

Rails.application.config.x.paypal_enabled =
  ENV["PAYPAL_CLIENT_ID"].present? && ENV["PAYPAL_CLIENT_SECRET"].present?

# OPSEC-032 parity: when the operator flips production to PayPal, boot must
# hold authoritative live credentials. Refusing to boot is the right failure
# mode — a silently-started prod app pointed at the sandbox (or unable to
# verify webhook signatures) is the actual incident we're preventing.
# Deliberately inert for every other provider value so this branch deploys
# with zero production impact until the flag flips.
if Rails.env.production? && provider == "paypal"
  unless ENV["PAYPAL_ENV"].to_s.strip.downcase == "live"
    raise "PAYPAL_ENV must be \"live\" in production when PAYMENT_PROVIDER=paypal — got #{ENV['PAYPAL_ENV'].inspect} (OPSEC-032 parity)"
  end
  %w[PAYPAL_CLIENT_ID PAYPAL_CLIENT_SECRET PAYPAL_WEBHOOK_ID].each do |key|
    if ENV[key].blank?
      raise "#{key} required in production when PAYMENT_PROVIDER=paypal (OPSEC-032 parity)"
    end
  end
end

if provider == "paypal" && !Rails.application.config.x.paypal_enabled
  Rails.logger.warn "[paypal] PAYMENT_PROVIDER=paypal but PAYPAL_CLIENT_ID/SECRET not set — PayPal checkout is disabled."
end
