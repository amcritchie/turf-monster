require "net/http"

module Paypal
  # Direct REST client for PayPal Orders v2 + webhook signature verification.
  #
  # Deliberately NOT the paypal-server-sdk gem: the SDK doesn't cover webhooks,
  # and direct REST keeps every call instrumented through OutboundRequestLogger
  # (service: "paypal") the way Stripe::Instrumentation does for Stripe — see
  # config/initializers/outbound_request_hooks.rb for the pattern this mirrors.
  #
  # Environment: PAYPAL_ENV "sandbox" (default) or "live" picks the API host.
  # Auth: OAuth2 client-credentials (PAYPAL_CLIENT_ID / PAYPAL_CLIENT_SECRET)
  # with an in-process token cache — PayPal tokens last ~9h, so one fetch per
  # process amortizes to ~0.
  class Client
    Error = Class.new(StandardError)

    SANDBOX_BASE = "https://api-m.sandbox.paypal.com".freeze
    LIVE_BASE    = "https://api-m.paypal.com".freeze
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    # Refresh the cached OAuth token this many seconds before PayPal's
    # advertised expiry so an in-flight request never rides an expired token.
    TOKEN_EXPIRY_SLACK = 120

    @token_cache = nil
    @token_mutex = Mutex.new

    class << self
      def env
        (ENV["PAYPAL_ENV"].presence || "sandbox").to_s.strip.downcase
      end

      def live?
        env == "live"
      end

      def sandbox?
        !live?
      end

      def base_url
        live? ? LIVE_BASE : SANDBOX_BASE
      end

      def reset_token_cache!
        @token_mutex.synchronize { @token_cache = nil }
      end

      # In-process OAuth token cache. The mutex is NOT held across the HTTP
      # fetch (yield) — two threads racing a cold cache both fetch, which is
      # harmless; the loser's token just overwrites the winner's.
      def cached_access_token
        @token_mutex.synchronize do
          cached = @token_cache
          return cached[:value] if cached && Time.current < cached[:expires_at]
        end
        token, expires_in = yield
        @token_mutex.synchronize do
          ttl = [expires_in.to_i - TOKEN_EXPIRY_SLACK, 60].max
          @token_cache = { value: token, expires_at: Time.current + ttl }
        end
        token
      end
    end

    # POST /v2/checkout/orders — intent CAPTURE. Amount derives from the pack
    # definition (server-side cents), never from anything client-supplied.
    # custom_id + invoice_id let the webhook handlers resolve the purchase row
    # even when the capture resource lacks the order id.
    def create_order(pack:, user:, purchase:)
      quantity = pack.fetch(:quantity)
      body = {
        intent: "CAPTURE",
        purchase_units: [{
          amount: {
            currency_code: "USD",
            value: format("%.2f", pack.fetch(:price_cents) / 100.0)
          },
          description: "Turf Monster — #{quantity} entry token#{'s' if quantity != 1}",
          custom_id: "paypal_purchase:#{purchase.id}",
          invoice_id: purchase.slug
        }]
      }
      request(:post, "/v2/checkout/orders", body: body)
    end

    # POST /v2/checkout/orders/{id}/capture. PayPal-Request-Id makes the call
    # idempotent at PayPal — the paypal_capture endpoint and the
    # CHECKOUT.ORDER.APPROVED webhook fallback can both fire for one order and
    # PayPal will return the same capture result to both.
    def capture_order(order_id)
      request(:post, "/v2/checkout/orders/#{order_id}/capture",
              body: {},
              headers: { "PayPal-Request-Id" => "capture-#{order_id}" })
    end

    def get_order(order_id)
      request(:get, "/v2/checkout/orders/#{order_id}")
    end

    # POST /v1/notifications/verify-webhook-signature. PayPal requires the
    # webhook_event "exactly as it was received, with no deviations" — so the
    # raw request body is spliced into the verification payload verbatim.
    # Re-serializing the parsed JSON can reorder keys / change whitespace and
    # fail verification. `headers` must expose the canonical uppercase
    # PAYPAL-* header names (request.headers does).
    def verify_webhook_signature(headers:, raw_body:)
      webhook_id = ENV["PAYPAL_WEBHOOK_ID"]
      if webhook_id.blank?
        Rails.logger.warn "[tokens] paypal.verify_skipped PAYPAL_WEBHOOK_ID not set"
        return false
      end

      fields = {
        "auth_algo"         => headers["PAYPAL-AUTH-ALGO"],
        "cert_url"          => headers["PAYPAL-CERT-URL"],
        "transmission_id"   => headers["PAYPAL-TRANSMISSION-ID"],
        "transmission_sig"  => headers["PAYPAL-TRANSMISSION-SIG"],
        "transmission_time" => headers["PAYPAL-TRANSMISSION-TIME"],
        "webhook_id"        => webhook_id
      }
      return false if fields.values.any?(&:blank?)

      payload = fields.to_json.sub(/\}\z/, %(,"webhook_event":#{raw_body}}))
      response = request(:post, "/v1/notifications/verify-webhook-signature", raw_json: payload)
      response["verification_status"] == "SUCCESS"
    rescue Error => e
      Rails.logger.error "[tokens] paypal.verify_error #{e.message}"
      false
    end

    private

    # Single instrumented entrypoint for every PayPal HTTP call. Mirrors the
    # ensure-style audit wrap of Solana::ClientLogger: success AND failure both
    # land in outbound_requests (OutboundRequestLogger sanitizes bodies —
    # access_token responses are redacted by the "token" sensitive-key rule).
    def request(http_method, path, body: nil, raw_json: nil, form: nil, headers: {}, auth: :bearer)
      started = Time.current
      response = nil
      error = nil

      begin
        response = perform(http_method, path, body: body, raw_json: raw_json, form: form, headers: headers, auth: auth)
        # A 401 on a bearer call means the cached token died early (revoked /
        # clock skew past the slack) — refresh once and retry.
        if response.code.to_i == 401 && auth == :bearer
          self.class.reset_token_cache!
          response = perform(http_method, path, body: body, raw_json: raw_json, form: form, headers: headers, auth: auth)
        end

        parsed = parse_body(response)
        unless response.code.to_i.between?(200, 299)
          name    = parsed["name"] || parsed["error"] || "http_#{response.code}"
          message = parsed["message"] || parsed["error_description"] || response.body.to_s[0, 300]
          raise Error, "PayPal #{http_method.to_s.upcase} #{path} → #{response.code} #{name}: #{message}"
        end
        parsed
      rescue => e
        error = e
        raise
      ensure
        record_outbound(http_method, path, body || form || raw_json, response, started, error)
      end
    end

    def perform(http_method, path, body:, raw_json:, form:, headers:, auth:)
      uri = URI.join(self.class.base_url, path)
      req =
        case http_method
        when :get  then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri)
        else raise ArgumentError, "unsupported HTTP method #{http_method}"
        end

      if auth == :basic
        req.basic_auth(ENV["PAYPAL_CLIENT_ID"].to_s, ENV["PAYPAL_CLIENT_SECRET"].to_s)
      else
        req["Authorization"] = "Bearer #{access_token}"
      end

      if form
        req.set_form_data(form)
      elsif raw_json
        req["Content-Type"] = "application/json"
        req.body = raw_json
      elsif body
        req["Content-Type"] = "application/json"
        req.body = body.to_json
      end
      headers.each { |key, value| req[key] = value }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.request(req)
    end

    def access_token
      self.class.cached_access_token { fetch_access_token }
    end

    def fetch_access_token
      response = request(:post, "/v1/oauth2/token",
                         form: { "grant_type" => "client_credentials" },
                         auth: :basic)
      [response.fetch("access_token"), response.fetch("expires_in").to_i]
    end

    def parse_body(response)
      return {} if response.body.blank?
      JSON.parse(response.body)
    rescue JSON::ParserError
      { "_raw" => response.body.to_s[0, 300] }
    end

    def record_outbound(http_method, path, request_body, response, started, error)
      OutboundRequestLogger.record!(
        service:       "paypal",
        method:        http_method.to_s.upcase,
        endpoint:      path,
        request_body:  request_body,
        response_body: response&.body,
        status_code:   response&.code&.to_i,
        duration_ms:   ((Time.current - started) * 1000).round,
        error_class:   error&.class&.to_s,
        error_message: error&.message
      )
    rescue => log_err
      Rails.logger.error "[outbound_request_logger] paypal hook failed: #{log_err.message}"
    end
  end
end
