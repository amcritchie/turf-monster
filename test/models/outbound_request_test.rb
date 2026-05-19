require "test_helper"

class OutboundRequestTest < ActiveSupport::TestCase
  test "successful and failed scopes split on status_code + error_class" do
    ok       = OutboundRequest.create!(service: "stripe", status_code: 200)
    err4xx   = OutboundRequest.create!(service: "stripe", status_code: 400)
    err5xx   = OutboundRequest.create!(service: "stripe", status_code: 503)
    raised   = OutboundRequest.create!(service: "solana_rpc", error_class: "Solana::Client::RpcError", error_message: "boom")
    no_code  = OutboundRequest.create!(service: "stripe") # no status, no error → treated as ok

    failed_ids     = OutboundRequest.failed.pluck(:id)
    successful_ids = OutboundRequest.successful.pluck(:id)

    assert_includes failed_ids, err4xx.id
    assert_includes failed_ids, err5xx.id
    assert_includes failed_ids, raised.id
    assert_includes successful_ids, ok.id
    assert_includes successful_ids, no_code.id
  end

  test "for_service scope filters by service" do
    s = OutboundRequest.create!(service: "stripe")
    r = OutboundRequest.create!(service: "solana_rpc")
    assert_equal [s.id], OutboundRequest.for_service("stripe").pluck(:id)
    assert_equal [r.id], OutboundRequest.for_service("solana_rpc").pluck(:id)
  end

  test "service is required" do
    rec = OutboundRequest.new
    assert_not rec.valid?
    assert_includes rec.errors[:service], "can't be blank"
  end

  test "failed? predicate matches scope" do
    assert OutboundRequest.new(error_class: "Foo").failed?
    assert OutboundRequest.new(status_code: 500).failed?
    assert_not OutboundRequest.new(status_code: 200).failed?
    assert_not OutboundRequest.new.failed?
  end
end
