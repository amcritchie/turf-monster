Rails.application.config.moonpay = {
  api_key: ENV["MOONPAY_API_KEY"],
  secret_key: ENV["MOONPAY_SECRET_KEY"],
  webhook_key: ENV["MOONPAY_WEBHOOK_KEY"],
  base_url: ENV.fetch("MOONPAY_BASE_URL", "https://buy-sandbox.moonpay.com")
}

# Production hardening (OPSEC-006): if the MoonPay top-up flow is enabled in
# production, every secret must be set. Fail-closed at boot rather than
# fail-open at webhook time (a missing webhook_key currently makes the
# webhook accept unsigned POSTs from any internet source).
if Rails.env.production? && ENV["MOONPAY_ENABLED"] == "true"
  missing = %w[MOONPAY_API_KEY MOONPAY_SECRET_KEY MOONPAY_WEBHOOK_KEY].select { |k| ENV[k].blank? }
  raise "MoonPay enabled in production but missing: #{missing.join(', ')}" if missing.any?
end
