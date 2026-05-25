module Solana
  # Prepended onto Solana::Client (from the solana-studio gem) to capture every
  # JSON-RPC call as an OutboundRequest row. Wrapped via prepend so we keep the
  # private visibility of the original `call` method.
  #
  # Activation: config/initializers/outbound_request_hooks.rb
  module ClientLogger
    # OPSEC-037: RPC methods whose first param is a base64 signed transaction.
    # A pre-broadcast partially-signed TX is replayable within the blockhash
    # window, and instruction data can carry payment references — never store
    # the raw payload in the outbound_requests audit table.
    REDACTED_TX_METHODS = %w[sendTransaction sendRawTransaction simulateTransaction].freeze

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
        # [BENCH] Caller-source trace. Walks the backtrace and finds the FIRST
        # frame that lives in our app or our gems (skip Ruby stdlib + gem internals
        # we don't own). Logs it next to the RPC so we can see who's spamming
        # Solana on /account. Remove after the N+1 hunt.
        begin
          app_frame = caller_locations(1, 80).find do |loc|
            p = loc.absolute_path.to_s
            next false unless p.include?("/projects/")
            next false if p.include?("/solana-studio")
            next false if p.include?("/client_logger.rb")
            next false if p.include?("/services/solana/vault.rb")
            true
          end
          gem_frame = caller_locations(1, 80).find do |loc|
            p = loc.absolute_path.to_s
            next false unless p.include?("/projects/")
            next false if p.include?("/client_logger.rb")
            true
          end
          tag = if app_frame
            "#{File.basename(File.dirname(app_frame.absolute_path))}/#{File.basename(app_frame.absolute_path)}:#{app_frame.lineno} #{app_frame.label}"
          else
            "??"
          end
          via = (gem_frame && gem_frame != app_frame) ? " via #{File.basename(gem_frame.absolute_path)}:#{gem_frame.lineno}" : ""
          Rails.logger.info("[BENCH-RPC] #{method} from #{tag}#{via}")
        rescue => trace_err
          Rails.logger.warn "[BENCH-RPC] trace failed: #{trace_err.message}"
        end

        begin
          OutboundRequestLogger.record!(
            service:       "solana_rpc",
            method:        method.to_s,
            endpoint:      (@rpc_url rescue nil),
            request_body:  { method: method.to_s, params: redact_rpc_params(method, params) },
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

    # OPSEC-037: replace a base64 signed-transaction payload with a hash +
    # byte length. Keeps any trailing config object (encoding, skipPreflight —
    # not sensitive); only the first param (the TX) is redacted.
    def redact_rpc_params(method, params)
      return params unless REDACTED_TX_METHODS.include?(method.to_s)
      return params unless params.is_a?(Array) && params[0].is_a?(String)

      tx = params[0]
      digest = Digest::SHA256.hexdigest(tx)
      ["[redacted tx — sha256:#{digest} (#{tx.bytesize} b64 bytes), OPSEC-037]"] + params[1..]
    end
  end
end
