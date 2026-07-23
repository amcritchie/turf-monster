require "test_helper"

# Coinflow::Client unit tests, stubbed at the Net::HTTP seam (house rule:
# minitest inline stubs only, no webmock/VCR — mirrors Paypal::ClientTest).
# Coinflow ships no Ruby SDK, so this client IS the integration layer; a scripted
# FakeHttp records every outgoing Net::HTTPRequest and replays a response queue.
class Coinflow::ClientTest < ActiveSupport::TestCase
  class FakeHttp
    Response = Struct.new(:code, :body)

    attr_reader :requests
    attr_accessor :use_ssl, :open_timeout, :read_timeout

    def initialize(responses)
      @responses = responses
      @requests  = []
    end

    def request(req)
      @requests << req
      raise "FakeHttp queue empty for #{req.method} #{req.path}" if @responses.empty?
      @responses.shift
    end
  end

  setup { @client = Coinflow::Client.new }

  def ok_link(link = "https://sandbox.coinflow.cash/solana/purchase-v2/turfmonster")
    FakeHttp::Response.new("200", { link: link }.to_json)
  end

  def with_env(key, value)
    original = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    original.nil? ? ENV.delete(key) : ENV[key] = original
  end

  # ── Environment ───────────────────────────────────────────────────────────

  test "base_url defaults to the sandbox host and sandbox? is true there" do
    assert Coinflow::Client.sandbox?
    assert_equal "https://api-sandbox.coinflow.cash", Coinflow::Client.base_url
  end

  # ── create_checkout_link ─────────────────────────────────────────────────

  test "create_checkout_link derives the pack subtotal and lists the wallet + card/paypal/venmo methods" do
    http = FakeHttp.new([ok_link])
    user = Struct.new(:id).new(42)

    link = Net::HTTP.stub(:new, http) do
      @client.create_checkout_link(
        user: user, pack: StripePurchase.pack("single"),
        return_url: "http://localhost:3111/tokens/buy?coinflow=return", ip: "1.2.3.4"
      )
    end
    assert_equal "https://sandbox.coinflow.cash/solana/purchase-v2/turfmonster", link

    req = http.requests.last
    assert_equal "POST", req.method
    assert_equal "/api/checkout/link", req.path
    assert_equal "tm_user_42", req["x-coinflow-auth-user-id"]

    body = JSON.parse(req.body)
    # Amount derives SERVER-SIDE from the pack — the caller only names a pack id.
    assert_equal 1900, body.dig("subtotal", "cents")
    assert_equal "USD", body.dig("subtotal", "currency")
    # The consumer rails, wallet buttons first: Apple/Google Pay + card + PayPal
    # + Venmo (bank/wire/SEPA/crypto/Cash App/APA/Interac all dropped).
    assert_equal %w[applePay googlePay card paypal venmo], body["allowedPaymentMethods"]
    assert_equal "http://localhost:3111/tokens/buy?coinflow=return",
                 body.dig("standaloneLinkConfig", "callbackUrl")
    assert_equal "1.2.3.4", body.dig("standaloneLinkConfig", "endUserDeviceIpAddress")
  end

  test "create_checkout_link raises Coinflow::Client::Error when the response has no link" do
    http = FakeHttp.new([FakeHttp::Response.new("200", {}.to_json)])
    assert_raises(Coinflow::Client::Error) do
      Net::HTTP.stub(:new, http) do
        @client.create_checkout_link(
          user: Struct.new(:id).new(7), pack: StripePurchase.pack("single"),
          return_url: "http://x", ip: "1.2.3.4"
        )
      end
    end
  end

  test "a non-2xx response raises with the Coinflow message" do
    http = FakeHttp.new([FakeHttp::Response.new("422", { message: "bad request" }.to_json)])
    err = assert_raises(Coinflow::Client::Error) do
      Net::HTTP.stub(:new, http) do
        @client.create_checkout_link(
          user: Struct.new(:id).new(7), pack: StripePurchase.pack("single"),
          return_url: "http://x", ip: "1.2.3.4"
        )
      end
    end
    assert_match(/422/, err.message)
    assert_match(/bad request/, err.message)
  end

  # ── verify_webhook_auth (shared-secret, constant-time, fails closed) ───────

  test "verify_webhook_auth matches the validation key and fails closed otherwise" do
    with_env("COINFLOW_WEBHOOK_VALIDATION_KEY", "secret-123") do
      assert @client.verify_webhook_auth("secret-123")
      refute @client.verify_webhook_auth("wrong-value")
      refute @client.verify_webhook_auth("")
      refute @client.verify_webhook_auth(nil)
    end
  end

  test "verify_webhook_auth fails closed when the validation key is unset" do
    with_env("COINFLOW_WEBHOOK_VALIDATION_KEY", nil) do
      refute @client.verify_webhook_auth("anything")
    end
  end
end
