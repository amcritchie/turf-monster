module Solana
  # Prepended onto Solana::Client (from the solana-studio gem) to capture every
  # JSON-RPC call as an OutboundRequest row. Wrapped via prepend so we keep the
  # private visibility of the original `call` method.
  #
  # Activation: config/initializers/outbound_request_hooks.rb
  module ClientLogger
    private

    def call(method, params = [])
      started = Time.current
      result = nil
      error  = nil

      begin
        result = super
      rescue => e
        error = e
        raise
      ensure
        begin
          OutboundRequestLogger.record!(
            service:       "solana_rpc",
            method:        method.to_s,
            endpoint:      (@rpc_url rescue nil),
            request_body:  { method: method.to_s, params: params },
            response_body: error ? nil : { result: result },
            status_code:   error ? nil : 200,
            duration_ms:   ((Time.current - started) * 1000).round,
            error_class:   error&.class&.to_s,
            error_message: error&.message
          )
        rescue => log_err
          Rails.logger.error "[outbound_request_logger] solana hook failed: #{log_err.message}"
        end
      end
    end
  end
end
