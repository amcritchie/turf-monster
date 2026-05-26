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

  test "logs a successful write call" do
    client = FakeClient.new
    assert_difference -> { OutboundRequest.count }, 1 do
      result = client.send(:call, "sendTransaction", ["BASE64SIGNED", { "encoding" => "base64" }])
      assert_equal "ok-for-sendTransaction", result["result"]
    end
    rec = OutboundRequest.last
    assert_equal "solana_rpc", rec.service
    assert_equal "sendTransaction", rec.method
    assert_equal 200, rec.status_code
    assert rec.duration_ms >= 0
    assert_nil rec.error_class
  end

  test "skips successful high-volume read methods to keep the audit table sane" do
    # Smell #1 from the 24h log review: getAccountInfo + getBalance + token
    # account scans were generating ~75 outbound_requests rows/min from one
    # dev machine. Successful reads are not audit-interesting; failures and
    # writes still log (see the next two tests).
    client = FakeClient.new
    %w[getAccountInfo getBalance getTokenAccountsByOwner getProgramAccounts].each do |m|
      assert_no_difference -> { OutboundRequest.count }, "expected no row for read method #{m}" do
        client.send(:call, m, [])
      end
    end
  end

  test "logs read methods when they ERROR (operational signal)" do
    # An RPC outage on read methods is operationally important — we want
    # those rows even though the happy-path reads are filtered.
    client = FailingClient.new
    assert_difference -> { OutboundRequest.count }, 1 do
      assert_raises(StandardError) { client.send(:call, "getAccountInfo") }
    end
    rec = OutboundRequest.last
    assert_equal "getAccountInfo", rec.method
    assert_equal "StandardError", rec.error_class
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

  test "redacts the signed-transaction param for sendTransaction (OPSEC-037)" do
    client = FakeClient.new
    raw_tx = "BASE64SIGNEDTX" + ("x" * 400)
    client.send(:call, "sendTransaction", [raw_tx, { "encoding" => "base64" }])
    params = OutboundRequest.last.request_body["params"]
    refute_includes params.to_s, raw_tx, "raw signed TX bytes must not be stored"
    assert_match(/redacted tx/, params.first.to_s)
    assert_match(/sha256:/, params.first.to_s)
  end
end
