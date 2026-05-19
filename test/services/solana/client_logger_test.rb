require "test_helper"

class Solana::ClientLoggerTest < ActiveSupport::TestCase
  # Build a minimal harness that mimics the gem's Client + the prepend chain
  # without hitting the real JSON-RPC endpoint.
  class FakeClient
    attr_accessor :rpc_url
    def initialize; @rpc_url = "https://fake.devnet.test"; end
    private
    def call(method, params = []); { "result" => "ok-for-#{method}", "echo" => params }; end
  end

  class FailingClient
    attr_accessor :rpc_url
    def initialize; @rpc_url = "https://fake.devnet.test"; end
    private
    def call(_method, _params = []); raise StandardError, "rpc boom"; end
  end

  setup do
    FakeClient.prepend(Solana::ClientLogger) unless FakeClient.ancestors.include?(Solana::ClientLogger)
    FailingClient.prepend(Solana::ClientLogger) unless FailingClient.ancestors.include?(Solana::ClientLogger)
  end

  test "logs a successful call" do
    client = FakeClient.new
    assert_difference -> { OutboundRequest.count }, 1 do
      result = client.send(:call, "getProgramAccounts", [{ filter: "x" }])
      assert_equal "ok-for-getProgramAccounts", result["result"]
    end
    rec = OutboundRequest.last
    assert_equal "solana_rpc", rec.service
    assert_equal "getProgramAccounts", rec.method
    assert_equal 200, rec.status_code
    assert rec.duration_ms >= 0
    assert_nil rec.error_class
  end

  test "logs and re-raises a failing call" do
    client = FailingClient.new
    assert_difference -> { OutboundRequest.count }, 1 do
      assert_raises(StandardError) { client.send(:call, "boom") }
    end
    rec = OutboundRequest.last
    assert_equal "solana_rpc", rec.service
    assert_equal "boom", rec.method
    assert_nil rec.status_code
    assert_equal "StandardError", rec.error_class
    assert_match(/rpc boom/, rec.error_message)
  end
end
