require "test_helper"

class Cdp::ClientTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body)

  setup do
    @original_key_id = ENV["CDP_API_KEY_ID"]
    @original_secret = ENV["CDP_API_KEY_SECRET"]
    signing_key = Ed25519::SigningKey.new(SecureRandom.bytes(32))
    ENV["CDP_API_KEY_ID"] = "test-key-id"
    ENV["CDP_API_KEY_SECRET"] = Base64.strict_encode64(
      signing_key.to_bytes + signing_key.verify_key.to_bytes
    )
    @client = Cdp::Client.new
  end

  teardown do
    restore_env("CDP_API_KEY_ID", @original_key_id)
    restore_env("CDP_API_KEY_SECRET", @original_secret)
  end

  test "parses a 2xx JSON body and records an outbound audit row" do
    response = FakeResponse.new("200", { token: "tok-123", channel_id: "" }.to_json)

    result = nil
    assert_difference -> { OutboundRequest.count }, 1 do
      @client.stub(:http_execute, response) do
        result = @client.post("/onramp/v1/token", { clientIp: "1.2.3.4" })
      end
    end

    assert_equal "tok-123", result["token"]

    rec = OutboundRequest.last
    assert_equal "cdp", rec.service
    assert_equal "post", rec.method
    assert_equal "https://api.developer.coinbase.com/onramp/v1/token", rec.endpoint
    assert_equal 200, rec.status_code
    assert_nil rec.error_class
  end

  test "GET appends query params to the path" do
    captured_uri = nil
    capture = ->(uri, _req) { captured_uri = uri; FakeResponse.new("200", "{}") }

    @client.stub(:http_execute, capture) do
      @client.get("/onramp/v1/buy/options", { country: "US", subdivision: "CA", networks: "solana" })
    end

    assert_equal "/onramp/v1/buy/options", captured_uri.path
    assert_equal "country=US&subdivision=CA&networks=solana", captured_uri.query
  end

  test "JWT uri claim binds the path WITHOUT the query string (official SDKs sign url.pathname)" do
    # If the query were signed and CDP verifies against path-only, the
    # failure mode is asymmetric: POST /onramp/v1/token (no query) works and
    # money moves, while every status poll / catalog GET 401s.
    signed = []
    recorder = lambda do |method:, path:|
      signed << [method, path]
      "fake-jwt"
    end
    captured_uri = nil
    capture = ->(uri, _req) { captured_uri = uri; FakeResponse.new("200", "{}") }

    Cdp::Auth.stub(:jwt_for, recorder) do
      @client.stub(:http_execute, capture) do
        @client.get("/onramp/v1/buy/options", { country: "US", subdivision: "CA", networks: "solana" })
      end
    end

    assert_equal [[:get, "/onramp/v1/buy/options"]], signed
    assert_equal "country=US&subdivision=CA&networks=solana", captured_uri.query,
                 "the query must stay on the actual request URI"
  end

  test "mints a FRESH JWT per request (never cached)" do
    jwt_calls = 0
    counter = lambda do |method:, path:|
      jwt_calls += 1
      assert_equal :get, method
      assert_equal "/onramp/v1/buy/config", path
      "fake-jwt-#{jwt_calls}"
    end

    Cdp::Auth.stub(:jwt_for, counter) do
      @client.stub(:http_execute, FakeResponse.new("200", "{}")) do
        @client.get("/onramp/v1/buy/config")
        @client.get("/onramp/v1/buy/config")
      end
    end

    assert_equal 2, jwt_calls
  end

  test "wraps 401 in AuthError with the CDP Status schema fields" do
    body = { code: 16, message: "JWT signature invalid", details: [] }.to_json
    error = assert_typed_error(Cdp::Client::AuthError, FakeResponse.new("401", body))
    assert_equal 401, error.status_code
    assert_equal 16, error.code
    assert_match(/JWT signature invalid/, error.message)
  end

  test "wraps 429 in RateLimitError" do
    body = { code: 8, message: "rate_limit_exceeded" }.to_json
    error = assert_typed_error(Cdp::Client::RateLimitError, FakeResponse.new("429", body))
    assert_equal 429, error.status_code
  end

  test "wraps other 4xx/5xx in ApiError, tolerating non-JSON bodies" do
    error = assert_typed_error(Cdp::Client::ApiError, FakeResponse.new("500", "<html>bad gateway</html>"))
    assert_equal 500, error.status_code
    assert_nil error.code
  end

  test "wraps network failures in ConnectionError and still records the audit row" do
    boom = ->(_uri, _req) { raise SocketError, "getaddrinfo failed" }

    assert_difference -> { OutboundRequest.count }, 1 do
      @client.stub(:http_execute, boom) do
        assert_raises(Cdp::Client::ConnectionError) { @client.get("/onramp/v1/buy/config") }
      end
    end

    rec = OutboundRequest.last
    assert_equal "Cdp::Client::ConnectionError", rec.error_class
    assert rec.failed?
  end

  test "money_value parses with BigDecimal, never Float" do
    value = Cdp::Client.money_value({ "value" => "19.000001", "currency" => "USDC" })
    assert_instance_of BigDecimal, value
    assert_equal BigDecimal("19.000001"), value

    assert_nil Cdp::Client.money_value(nil)
    assert_nil Cdp::Client.money_value({ "value" => "", "currency" => "USD" })
  end

  private

  def assert_typed_error(klass, response)
    @client.stub(:http_execute, response) do
      assert_raises(klass) { @client.get("/onramp/v1/buy/config") }
    end
  end

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
