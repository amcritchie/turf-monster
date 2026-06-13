require "test_helper"

# Rate-limit epic, Phase 1 — the 429 response CONTRACT the client interceptor
# (authedFetch) depends on: a general-tier throttle must tag the 429 with
# X-RateLimit-Tier: general (header + body) so the global wait modal opens,
# while an auth-surface throttle tags "auth" so it's left to its own inline UX.
# Unit-tests the custom throttled_responder directly (rack-attack is disabled in
# test env; tripping the real middleware also pulls in Solana/auth side effects).
# The end-to-end trip → modal is verified manually on :3001.
class RateLimitResponderTest < ActiveSupport::TestCase
  def call_responder(matched:, period:)
    env = {
      "rack.attack.matched"    => matched,
      "rack.attack.match_data" => { period: period }
    }
    Rack::Attack.throttled_responder.call(ActionDispatch::Request.new(env))
  end

  test "a general-tier throttle tags the 429 general (header + body) with Retry-After" do
    status, headers, body = call_responder(matched: "faucet/ip", period: 60)

    assert_equal 429, status
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal "60", headers["Retry-After"]
    json = JSON.parse(body.first)
    assert_equal "general", json["tier"]
    assert_equal 60, json["retry_after"]
  end

  test "the new general/ip backstop is tagged general" do
    _, headers, body = call_responder(matched: "general/ip", period: 60)
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal "general", JSON.parse(body.first)["tier"]
  end

  test "the cdp_sessions/user throttle is tagged general (wait modal, not inline auth UX)" do
    _, headers, body = call_responder(matched: "cdp_sessions/user", period: 60)
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal "general", JSON.parse(body.first)["tier"]
  end

  test "the check_funding/ip throttle is tagged general (wait modal — beginFundingCheck uses authedFetch)" do
    _, headers, body = call_responder(matched: "check_funding/ip", period: 60)
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal "general", JSON.parse(body.first)["tier"]
  end

  test "an auth-surface throttle tags the 429 auth so the wait modal stays out of it" do
    _, headers, body = call_responder(matched: "magic_link/email", period: 3600)
    assert_equal "auth", headers["X-RateLimit-Tier"]
    assert_equal "auth", JSON.parse(body.first)["tier"]
  end
end
