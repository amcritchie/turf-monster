# Heroku Redis serves rediss:// (TLS) with a self-signed cert. redis-client
# verifies peer certs by default and rejects it, crashing the Sidekiq server
# at boot. rediss:// keeps the connection encrypted; we only skip chain
# verification — Heroku's documented guidance for their Redis add-on.
redis_config = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
if redis_config[:url].start_with?("rediss://")
  redis_config[:ssl_params] = { verify_mode: OpenSSL::SSL::VERIFY_NONE }
end

Sidekiq.configure_server { |config| config.redis = redis_config }
Sidekiq.configure_client { |config| config.redis = redis_config }
