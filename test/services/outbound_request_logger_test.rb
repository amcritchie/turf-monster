require "test_helper"
require "minitest/mock"

class OutboundRequestLoggerTest < ActiveSupport::TestCase
  test "records a row with basic fields" do
    assert_difference -> { OutboundRequest.count }, 1 do
      OutboundRequestLogger.record!(
        service: "stripe", method: "POST", endpoint: "/v1/checkout/sessions",
        status_code: 200, duration_ms: 250
      )
    end
    rec = OutboundRequest.last
    assert_equal "stripe", rec.service
    assert_equal "POST", rec.method
    assert_equal 200, rec.status_code
    assert_equal 250, rec.duration_ms
  end

  test "redacts sensitive keys in request_body" do
    OutboundRequestLogger.record!(
      service: "stripe",
      request_body: { api_key: "sk_test_abc", quantity: 1, customer_email: "x@y.com" }
    )
    body = OutboundRequest.last.request_body
    assert_equal "[REDACTED]", body["api_key"]
    assert_equal "[REDACTED]", body["customer_email"]
    assert_equal 1,            body["quantity"]
  end

  test "redacts nested sensitive keys" do
    OutboundRequestLogger.record!(
      service: "stripe",
      request_body: { metadata: { quantity: 3, secret: "nope" }, headers: { authorization: "Bearer xyz" } }
    )
    body = OutboundRequest.last.request_body
    assert_equal "[REDACTED]", body["metadata"]["secret"]
    assert_equal 3,            body["metadata"]["quantity"]
    assert_equal "[REDACTED]", body["headers"]["authorization"]
  end

  test "truncates response_body above MAX_BODY_BYTES" do
    big = "x" * 30_000
    OutboundRequestLogger.record!(service: "stripe", response_body: { blob: big })
    body = OutboundRequest.last.response_body
    assert body["_truncated"]
    assert body["original_bytesize"] > OutboundRequestLogger::MAX_BODY_BYTES
    assert body["preview"].bytesize <= OutboundRequestLogger::MAX_BODY_BYTES
  end

  test "swallows DB errors so the caller is not broken" do
    OutboundRequest.stub :create!, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "db down" } do
      result = OutboundRequestLogger.record!(service: "stripe")
      assert_nil result
    end
  end

  test "coerces non-hash body (string + array) without raising" do
    OutboundRequestLogger.record!(service: "solana_rpc", response_body: "raw text reply")
    assert OutboundRequest.last.response_body.is_a?(Hash)

    OutboundRequestLogger.record!(service: "solana_rpc", response_body: [1, 2, 3])
    assert OutboundRequest.last.response_body.is_a?(Hash)
  end
end
