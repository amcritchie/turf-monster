require "test_helper"

# Paypal::Client unit tests, stubbed at the Net::HTTP seam. Unlike the Stripe
# tests (which stub the gem's API objects) there is no gem layer above this
# client — it IS the integration layer — so a scripted FakeHttp records every
# outgoing Net::HTTPRequest and replays a response queue. No webmock/VCR
# (house rule: minitest inline stubs only).
class Paypal::ClientTest < ActiveSupport::TestCase
  class FakeHttp
    Response = Struct.new(:code, :body)

    attr_reader :requests
    attr_accessor :use_ssl, :open_timeout, :read_timeout

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(req)
      @requests << req
      raise "FakeHttp queue empty for #{req.method} #{req.path}" if @responses.empty?
      @responses.shift
    end
  end

  VERIFY_HEADERS = {
    "PAYPAL-AUTH-ALGO" => "SHA256withRSA",
    "PAYPAL-CERT-URL" => "https://api.paypal.com/cert",
    "PAYPAL-TRANSMISSION-ID" => "tid-1",
    "PAYPAL-TRANSMISSION-SIG" => "sig-1",
    "PAYPAL-TRANSMISSION-TIME" => "2026-06-09T00:00:00Z"
  }.freeze

  setup do
    Paypal::Client.reset_token_cache!
    @client = Paypal::Client.new
  end

  teardown do
    Paypal::Client.reset_token_cache!
  end

  # ── Environment selection ────────────────────────────────────────────────

  test "sandbox is the default environment; live flips the base URL" do
    assert Paypal::Client.sandbox?
    refute Paypal::Client.live?
    assert_equal "https://api-m.sandbox.paypal.com", Paypal::Client.base_url

    Paypal::Client.stub :env, "live" do
      assert Paypal::Client.live?
      assert_equal "https://api-m.paypal.com", Paypal::Client.base_url
    end
  end

  # ── OAuth token fetch / cache / expiry ──────────────────────────────────

  test "cold cache fetches a token with Basic client credentials, then sends Bearer" do
    http = FakeHttp.new([oauth_response("tok_1"), ok_response("id" => "ORD")])
    with_env("PAYPAL_CLIENT_ID" => "cid", "PAYPAL_CLIENT_SECRET" => "shh") do
      Net::HTTP.stub(:new, http) { @client.get_order("ORD") }
    end

    oauth, get = http.requests
    assert_equal "/v1/oauth2/token", oauth.path
    assert_equal "POST", oauth.method
    assert_equal "Basic #{Base64.strict_encode64('cid:shh')}", oauth["authorization"]
    assert_equal "grant_type=client_credentials", oauth.body
    assert_equal "GET", get.method
    assert_equal "/v2/checkout/orders/ORD", get.path
    assert_equal "Bearer tok_1", get["authorization"]
  end

  test "token is cached in-process — the second call skips the OAuth fetch" do
    http = FakeHttp.new([oauth_response("tok_1"), ok_response({}), ok_response({})])
    Net::HTTP.stub :new, http do
      @client.get_order("A")
      @client.get_order("B")
    end

    assert_equal 1, http.requests.count { |r| r.path == "/v1/oauth2/token" }
    assert_equal "Bearer tok_1", http.requests.last["authorization"]
  end

  test "an expired cached token is refetched, honoring the expiry slack" do
    http = FakeHttp.new([
      oauth_response("tok_old", expires_in: 600),
      ok_response({}),
      oauth_response("tok_new", expires_in: 600),
      ok_response({})
    ])
    Net::HTTP.stub :new, http do
      @client.get_order("A")
      # Cached TTL is expires_in minus the slack — one second past that must refetch.
      travel((600 - Paypal::Client::TOKEN_EXPIRY_SLACK).seconds + 1.second) do
        @client.get_order("B")
      end
    end

    assert_equal 2, http.requests.count { |r| r.path == "/v1/oauth2/token" }
    assert_equal "Bearer tok_new", http.requests.last["authorization"]
  end

  test "a 401 on a bearer call refreshes the token once and retries" do
    http = FakeHttp.new([
      oauth_response("tok_stale"),
      response(401, "error" => "invalid_token"),
      oauth_response("tok_fresh"),
      ok_response("id" => "ORD")
    ])
    result = Net::HTTP.stub(:new, http) { @client.get_order("ORD") }

    assert_equal "ORD", result["id"]
    assert_equal %w[/v1/oauth2/token /v2/checkout/orders/ORD /v1/oauth2/token /v2/checkout/orders/ORD],
                 http.requests.map(&:path)
    assert_equal "Bearer tok_fresh", http.requests.last["authorization"]
  end

  # ── Orders v2 ────────────────────────────────────────────────────────────

  test "create_order derives the USD amount server-side from the pack and tags custom_id + invoice_id" do
    user = users(:jordan)
    purchase = PaypalPurchase.create!(
      user: user, pack_id: "trio", quantity: 3, price_cents: 49_00,
      wallet_address: "W#{SecureRandom.hex(3)}", status: "pending"
    )
    http = FakeHttp.new([oauth_response, ok_response("id" => "ORDER_NEW", "status" => "CREATED")])
    order = Net::HTTP.stub(:new, http) do
      @client.create_order(pack: StripePurchase.pack("trio"), user: user, purchase: purchase)
    end

    assert_equal "ORDER_NEW", order["id"]
    req = http.requests.last
    assert_equal "/v2/checkout/orders", req.path
    body = JSON.parse(req.body)
    assert_equal "CAPTURE", body["intent"]
    unit = body["purchase_units"].first
    assert_equal({ "currency_code" => "USD", "value" => "49.00" }, unit["amount"])
    assert_equal "paypal_purchase:#{purchase.id}", unit["custom_id"]
    assert_equal purchase.slug, unit["invoice_id"]
  end

  test "capture_order posts to the capture endpoint with an idempotent PayPal-Request-Id" do
    http = FakeHttp.new([oauth_response, ok_response("id" => "ORD", "status" => "COMPLETED")])
    Net::HTTP.stub(:new, http) { @client.capture_order("ORD") }

    req = http.requests.last
    assert_equal "POST", req.method
    assert_equal "/v2/checkout/orders/ORD/capture", req.path
    assert_equal "capture-ORD", req["PayPal-Request-Id"]
  end

  test "non-2xx responses raise Paypal::Client::Error carrying PayPal's error name and message" do
    http = FakeHttp.new([
      oauth_response,
      response(422, "name" => "ORDER_ALREADY_CAPTURED", "message" => "Order already captured.")
    ])
    error = assert_raises(Paypal::Client::Error) do
      Net::HTTP.stub(:new, http) { @client.capture_order("ORD") }
    end
    assert_match(/422 ORDER_ALREADY_CAPTURED/, error.message)
    assert_match(/Order already captured/, error.message)
  end

  # ── Webhook signature verification ──────────────────────────────────────

  test "verify_webhook_signature posts the verification fields with the RAW body spliced verbatim" do
    raw = '{"id":"WH-1","event_type":"PAYMENT.CAPTURE.COMPLETED",  "spacing":"preserved"}'
    http = FakeHttp.new([oauth_response, ok_response("verification_status" => "SUCCESS")])
    result = with_env("PAYPAL_WEBHOOK_ID" => "WHID") do
      Net::HTTP.stub(:new, http) { @client.verify_webhook_signature(headers: VERIFY_HEADERS, raw_body: raw) }
    end

    assert result
    req = http.requests.last
    assert_equal "/v1/notifications/verify-webhook-signature", req.path
    assert_includes req.body, %("webhook_event":#{raw}), "raw body must pass through byte-for-byte"
    posted = JSON.parse(req.body)
    assert_equal "WHID", posted["webhook_id"]
    assert_equal "SHA256withRSA", posted["auth_algo"]
    assert_equal "tid-1", posted["transmission_id"]
    assert_equal "sig-1", posted["transmission_sig"]
  end

  test "verify_webhook_signature is false when PayPal does not answer SUCCESS" do
    http = FakeHttp.new([oauth_response, ok_response("verification_status" => "FAILURE")])
    result = with_env("PAYPAL_WEBHOOK_ID" => "WHID") do
      Net::HTTP.stub(:new, http) { @client.verify_webhook_signature(headers: VERIFY_HEADERS, raw_body: "{}") }
    end
    refute result
  end

  test "verify_webhook_signature is false without PAYPAL_WEBHOOK_ID — no HTTP call" do
    http = FakeHttp.new([])
    result = with_env("PAYPAL_WEBHOOK_ID" => nil) do
      Net::HTTP.stub(:new, http) { @client.verify_webhook_signature(headers: VERIFY_HEADERS, raw_body: "{}") }
    end
    refute result
    assert_empty http.requests
  end

  test "verify_webhook_signature is false when a transmission header is missing — no HTTP call" do
    http = FakeHttp.new([])
    headers = VERIFY_HEADERS.merge("PAYPAL-TRANSMISSION-SIG" => nil)
    result = with_env("PAYPAL_WEBHOOK_ID" => "WHID") do
      Net::HTTP.stub(:new, http) { @client.verify_webhook_signature(headers: headers, raw_body: "{}") }
    end
    refute result
    assert_empty http.requests
  end

  test "verify_webhook_signature fails closed when the verification API errors" do
    http = FakeHttp.new([oauth_response, response(500, "name" => "INTERNAL_SERVICE_ERROR")])
    result = with_env("PAYPAL_WEBHOOK_ID" => "WHID") do
      Net::HTTP.stub(:new, http) { @client.verify_webhook_signature(headers: VERIFY_HEADERS, raw_body: "{}") }
    end
    refute result
  end

  # ── OutboundRequest audit trail ──────────────────────────────────────────

  test "every call records an OutboundRequest row, with the OAuth token redacted" do
    http = FakeHttp.new([oauth_response("tok_secret"), ok_response("id" => "ORD")])
    assert_difference -> { OutboundRequest.where(service: "paypal").count }, 2 do
      Net::HTTP.stub(:new, http) { @client.get_order("ORD") }
    end

    oauth_row = OutboundRequest.where(service: "paypal", endpoint: "/v1/oauth2/token").order(:id).last
    assert_equal 200, oauth_row.status_code
    assert_equal "[REDACTED]", oauth_row.response_body["access_token"],
                 "OAuth token must never land in the audit log"

    get_row = OutboundRequest.where(service: "paypal", endpoint: "/v2/checkout/orders/ORD").order(:id).last
    assert_equal "GET", get_row.method
    assert get_row.successful?
  end

  test "webhook verification audit row redacts webhook_id and transmission_sig" do
    http = FakeHttp.new([oauth_response, ok_response("verification_status" => "SUCCESS")])
    with_env("PAYPAL_WEBHOOK_ID" => "WHID") do
      Net::HTTP.stub(:new, http) { @client.verify_webhook_signature(headers: VERIFY_HEADERS, raw_body: "{}") }
    end

    row = OutboundRequest.where(service: "paypal", endpoint: "/v1/notifications/verify-webhook-signature").order(:id).last
    assert_equal "[REDACTED]", row.request_body["webhook_id"],
                 "PAYPAL_WEBHOOK_ID is an operator credential — it must not sit cleartext in a 90/180-day audit table"
    assert_equal "[REDACTED]", row.request_body["transmission_sig"]
    assert_equal "[REDACTED]", row.request_body["auth_algo"], "pre-existing 'auth' substring rule"
  end

  test "a failed call records the error on its OutboundRequest row" do
    http = FakeHttp.new([
      oauth_response,
      response(422, "name" => "ORDER_ALREADY_CAPTURED", "message" => "nope")
    ])
    assert_raises(Paypal::Client::Error) do
      Net::HTTP.stub(:new, http) { @client.capture_order("ORD") }
    end

    row = OutboundRequest.where(service: "paypal", endpoint: "/v2/checkout/orders/ORD/capture").order(:id).last
    assert_equal 422, row.status_code
    assert_equal "Paypal::Client::Error", row.error_class
    assert row.failed?
  end

  private

  def oauth_response(token = "tok_#{SecureRandom.hex(2)}", expires_in: 32_400)
    ok_response("access_token" => token, "token_type" => "Bearer", "expires_in" => expires_in)
  end

  def ok_response(body)
    response(200, body)
  end

  def response(code, body)
    FakeHttp::Response.new(code.to_s, body.to_json)
  end

  def with_env(overrides)
    saved = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
