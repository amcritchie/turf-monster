require "test_helper"

# Single-use enforcement can't be exercised against the test :null_store, so we
# inject a real MemoryStore here (the production path uses the Redis cache).
class MagicLinkTest < ActiveSupport::TestCase
  setup do
    MagicLink.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    MagicLink.cache = nil
  end

  test "generate then consume returns the normalized email and return_to" do
    token = MagicLink.generate(email: "  New@Example.com ", return_to: "/contests/abc")
    result = MagicLink.consume(token)
    assert_equal "new@example.com", result.email
    assert_equal "/contests/abc", result.return_to
  end

  test "consume is single-use — a second consume is rejected" do
    token = MagicLink.generate(email: "a@b.com")
    MagicLink.consume(token)
    assert_raises(MagicLink::InvalidToken) { MagicLink.consume(token) }
  end

  test "tampered token is rejected" do
    token = MagicLink.generate(email: "a@b.com")
    assert_raises(MagicLink::InvalidToken) { MagicLink.consume("#{token}x") }
  end

  test "expired token is rejected" do
    token = MagicLink.generate(email: "a@b.com")
    travel(MagicLink::TTL + 1.minute) do
      assert_raises(MagicLink::InvalidToken) { MagicLink.consume(token) }
    end
  end

  test "token is URL-safe (no slash) even when return_to carries a path" do
    # Regression: the route constraint is %r{[^/]+}; a standard-base64 token
    # with a "/" broke URL generation in the mailer. Must round-trip cleanly.
    rt = "/contests/test9971?picks=390,400,399,430,429,395"
    token = MagicLink.generate(email: "a@b.com", return_to: rt)
    assert_not token.include?("/"), "token must be URL-safe (no '/')"
    assert_equal rt, MagicLink.consume(token).return_to
  end

  test "protocol-relative and absolute return_to are dropped" do
    %w[//evil.com/x https://evil.com relative/path].each do |bad|
      token = MagicLink.generate(email: "a@b.com", return_to: bad)
      assert_nil MagicLink.consume(token).return_to, "expected #{bad.inspect} to be dropped"
    end
  end
end
