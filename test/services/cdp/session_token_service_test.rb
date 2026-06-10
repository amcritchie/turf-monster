require "test_helper"

class Cdp::SessionTokenServiceTest < ActiveSupport::TestCase
  # Captures the POST body so we can assert the exact request shape.
  class FakeClient
    attr_reader :posts

    def initialize(response)
      @response = response
      @posts = []
    end

    def post(path, body)
      @posts << [path, body]
      @response
    end
  end

  test "mints a token with the documented camelCase body shape" do
    client = FakeClient.new({ "token" => "sess-abc", "channel_id" => "" })
    service = Cdp::SessionTokenService.new(client: client)

    token = service.mint(address: "So1anaPubkey111", client_ip: "203.0.113.9")

    assert_equal "sess-abc", token
    path, body = client.posts.first
    assert_equal "/onramp/v1/token", path
    assert_equal [{ address: "So1anaPubkey111", blockchains: ["solana"] }], body[:addresses]
    assert_equal ["USDC"], body[:assets]
    assert_equal "203.0.113.9", body[:clientIp]
  end

  test "raises ApiError when the response has no token" do
    client = FakeClient.new({ "channel_id" => "" })
    service = Cdp::SessionTokenService.new(client: client)

    assert_raises(Cdp::Client::ApiError) do
      service.mint(address: "So1anaPubkey111", client_ip: "203.0.113.9")
    end
  end

  test "refuses a blank address before hitting the API" do
    client = FakeClient.new({ "token" => "never-used" })
    service = Cdp::SessionTokenService.new(client: client)

    assert_raises(ArgumentError) { service.mint(address: nil, client_ip: "203.0.113.9") }
    assert_empty client.posts
  end
end
