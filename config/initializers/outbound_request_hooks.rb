# Wires OutboundRequestLogger into the third-party HTTP clients used by this app.
#
#   - Stripe        — via the SDK's Instrumentation.subscribe(:request_end)
#   - Solana RPC    — via prepending Solana::ClientLogger onto the gem's Client class
#   - MoonPay       — (future) once a SDK or wrapper is in place
#
# Failure of either hook is logged but never raises — these are observability
# wires, not part of the request path.

# ── Solana::Client#call wrapper ──────────────────────────────────────────────
Rails.application.config.to_prepare do
  begin
    Solana::Client.prepend(Solana::ClientLogger)
  rescue => e
    Rails.logger.error "[outbound_request_hooks] failed to prepend Solana::ClientLogger: #{e.class}: #{e.message}"
  end
end

# ── Stripe::Instrumentation subscription ─────────────────────────────────────
if defined?(Stripe::Instrumentation)
  Stripe::Instrumentation.subscribe(:request_end) do |event|
    begin
      OutboundRequestLogger.record!(
        service:       "stripe",
        method:        (event.respond_to?(:method) ? event.method.to_s.upcase : nil),
        endpoint:      (event.respond_to?(:path)   ? event.path : nil),
        request_body:  {
          query: (event.respond_to?(:query) ? event.query : nil),
          body:  (event.respond_to?(:body)  ? event.body  : nil)
        },
        # Stripe's instrumentation API does not expose response bodies.
        response_body: nil,
        status_code:   (event.respond_to?(:http_status) ? event.http_status : nil),
        duration_ms:   (event.respond_to?(:duration) && event.duration ? (event.duration * 1000).round : nil),
        error_class:   nil,
        error_message: nil
      )
    rescue => e
      Rails.logger.error "[outbound_request_hooks] stripe subscribe failed: #{e.class}: #{e.message}"
    end
  end
else
  Rails.logger.warn "[outbound_request_hooks] Stripe::Instrumentation not loaded — Stripe call logging disabled."
end
