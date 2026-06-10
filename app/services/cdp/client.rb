require "net/http"

module Cdp
  # Thin HTTP wrapper for the Coinbase CDP REST API
  # (https://api.developer.coinbase.com). See docs/CDP_RAMP_INTEGRATION.md §4.
  #
  # - Fresh Cdp::Auth JWT per request (120s TTL + per-URI binding — never cached).
  # - Casing is mixed BY DESIGN: request bodies camelCase ("addresses",
  #   "clientIp"), v1 responses snake_case ("partner_user_ref", "to_address"),
  #   webhook payloads camelCase. Translate at call sites — no global key
  #   transform here.
  # - Money pairs are {value: String, currency: String} — parse `value` with
  #   Cdp::Client.money_value (BigDecimal), never Float.
  # - Every call records an OutboundRequest row (service "cdp") for parity with
  #   the Stripe/Solana outbound audit stack.
  class Client
    HOST = Cdp::Auth::HOST
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    # Typed errors wrapping the CDP Status schema {code, message, details}.
    class Error < StandardError
      attr_reader :status_code, :code, :details

      def initialize(message, status_code: nil, code: nil, details: nil)
        super(message)
        @status_code = status_code
        @code = code
        @details = details
      end
    end
    class AuthError       < Error; end # 401 / 403 — key misconfig or revoked
    class RateLimitError  < Error; end # 429 — incl. undocumented token-mint throttle
    class ApiError        < Error; end # other 4xx/5xx
    class ConnectionError < Error; end # network layer (timeout, DNS, TLS)

    # Parse a CDP money pair's value — BigDecimal, never Float.
    def self.money_value(money)
      return nil if money.nil?
      value = money.is_a?(Hash) ? (money["value"] || money[:value]) : money
      return nil if value.nil? || value.to_s.strip.empty?
      BigDecimal(value.to_s)
    end

    def get(path, params = {})
      request(:get, path, params: params)
    end

    def post(path, body = {})
      request(:post, path, body: body)
    end

    private

    def request(method, path, params: nil, body: nil)
      full_path = path
      if params.present?
        full_path = "#{path}?#{URI.encode_www_form(params)}"
      end
      uri = URI("https://#{HOST}#{full_path}")

      req = build_request(method, uri, path, body)
      started = Time.current
      response = nil
      error = nil

      begin
        response = http_execute(uri, req)
      rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, EOFError, IOError => e
        error = ConnectionError.new("CDP request failed: #{e.class}: #{e.message}")
        raise error
      ensure
        log_outbound(method, full_path, body, response, started, error)
      end

      handle_response(response)
    end

    def build_request(method, uri, path, body)
      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = klass.new(uri.request_uri)
      # Fresh JWT per request — bound to this exact METHOD + host + path,
      # WITHOUT the query string. Every official CDP JWT example signs
      # url.pathname only (and the Coinbase REST auth docs say not to include
      # query params in the signed path); signing the query would 401 every
      # GET-with-params (status polls, catalog) while query-less POSTs kept
      # working. The query stays on the actual request URI (uri.request_uri).
      signing_path = path.to_s.split("?").first
      req["Authorization"] = "Bearer #{Cdp::Auth.jwt_for(method: method, path: signing_path)}"
      req["Content-Type"] = "application/json"
      req.body = body.to_json if body
      req
    end

    # Seam for tests (house pattern: stub at the transport boundary, like the
    # Solana::ClientLogger fakes). Returns a Net::HTTPResponse-shaped object
    # responding to #code and #body.
    def http_execute(uri, req)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(req)
      end
    end

    def handle_response(response)
      status = response.code.to_i
      parsed = parse_json(response.body)
      return parsed if status >= 200 && status < 300

      # CDP error Status schema: {code, message, details}
      message = parsed.is_a?(Hash) ? (parsed["message"] || response.body.to_s[0, 500]) : response.body.to_s[0, 500]
      code    = parsed.is_a?(Hash) ? parsed["code"] : nil
      details = parsed.is_a?(Hash) ? parsed["details"] : nil

      klass =
        case status
        when 401, 403 then AuthError
        when 429      then RateLimitError
        else               ApiError
        end
      raise klass.new("CDP #{status}: #{message}", status_code: status, code: code, details: details)
    end

    def parse_json(raw)
      return {} if raw.nil? || raw.empty?
      JSON.parse(raw)
    rescue JSON::ParserError
      { "_raw" => raw.to_s[0, 500] }
    end

    def log_outbound(method, full_path, body, response, started, error)
      OutboundRequestLogger.record!(
        service:       "cdp",
        method:        method.to_s,
        endpoint:      "https://#{HOST}#{full_path}",
        request_body:  body,
        response_body: response&.body,
        status_code:   response&.code&.to_i,
        duration_ms:   ((Time.current - started) * 1000).round,
        error_class:   error&.class&.to_s,
        error_message: error&.message
      )
    end
  end
end
