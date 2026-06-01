# OPSEC-019: rate limiting via rack-attack.
#
# Protects:
#   - login + wallet-auth endpoints from credential stuffing / sybil signup
#   - webhook endpoints from signature-verification DoS
#   - faucet / airdrop from devnet abuse (also defense-in-depth on top of
#     the OPSEC-020 production guards)
#   - email verification + Stripe checkout from request flood / fee bleed
#
# Throttles are intentionally generous for legit usage. If you see a
# legit user hitting a throttle in error logs, raise the limit. The point
# is to make scripted brute force expensive, not to harass humans.
#
# Caching: defaults to Rails.cache. In production set REDIS_URL → Rails
# uses Redis-backed cache automatically. Disabled in test env so tests
# don't accidentally hit throttles (an explicit Rack::Attack-aware test
# can re-enable via Rack::Attack.enabled = true around its assertions).

Rails.application.config.middleware.use Rack::Attack

if Rails.env.test?
  Rack::Attack.enabled = false
end

class Rack::Attack
  ### Throttle: login (engine route) — IP + email
  # Browser flow targets — keep moderate (a real user fat-fingering 6 times shouldn't lock out)
  throttle("login/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/login"
  end

  throttle("login/email", limit: 5, period: 1.minute) do |req|
    if req.post? && req.path == "/login"
      req.params["email"].to_s.downcase.presence
    end
  end

  ### Throttle: Solana wallet auth — nonce + verify
  throttle("solana_nonce/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.get? && req.path == "/auth/solana/nonce"
  end

  throttle("solana_verify/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/auth/solana/verify"
  end

  ### Throttle: account-linking wallet sig (logged-in)
  throttle("link_solana/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/account/link_solana"
  end

  ### Throttle: webhook endpoints — DoS protection on signature verification
  # Stripe / MoonPay normally deliver a handful per second at peak. 100/min
  # leaves ample headroom while killing flood attacks.
  throttle("webhooks/stripe", limit: 100, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/webhooks/stripe"
  end

  throttle("webhooks/moonpay", limit: 100, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/webhooks/moonpay"
  end

  ### Throttle: devnet faucet / airdrop — money-cost endpoints
  # Faucet is already prod-disabled per OPSEC-020 but rate-limited on devnet
  # too because admin SOL gets burned via mint_spl + ATA creation.
  throttle("faucet/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/faucet"
  end

  throttle("airdrop/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/wallet/airdrop"
  end

  ### Throttle: Stripe checkout creation — fee bleed protection
  throttle("stripe_checkout/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && (req.path == "/tokens/stripe_checkout" || req.path == "/wallet/stripe_deposit")
  end

  ### Throttle: email verification — outbound spam prevention
  throttle("email_verification/ip", limit: 3, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/email_verification"
  end

  ### Throttle: magic-link request — outbound email spam + can't-spam-a-mailbox
  # Per-email is the important cap (limits mail to a single address); IP is a
  # generous backstop for shared NATs. Consume (GET /magic_link/:token) is not
  # throttled — brute-forcing an HMAC token is infeasible and legit clicks must
  # always go through.
  throttle("magic_link/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/magic_link"
  end
  throttle("magic_link/email", limit: 3, period: 1.hour) do |req|
    req.params["email"].to_s.downcase.presence if req.post? && req.path == "/magic_link"
  end

  ### Throttle: contest chat — message-post flood backstop
  # Coarse per-IP cap; MessagesController enforces a precise per-user cooldown.
  throttle("chat_messages/ip", limit: 40, period: 1.minute) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/contests/[^/]+/messages\z})
  end

  ### Throttle: signup — sybil + spam prevention (prelaunch audit H5)
  # Engine route POST /signup is the browser-flow registration. The magic-link
  # request (POST /magic_link) is the primary email-signup surface now and is
  # throttled by the magic_link rules above.
  throttle("signup/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/signup"
  end

  ### Throttle: wallet withdraw — money-out, strict cap (prelaunch audit H5)
  throttle("wallet_withdraw/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/wallet/withdraw"
  end

  ### Throttle: MoonPay deposit initiate — fee-bleed protection (prelaunch audit H5)
  # Stripe deposit is already covered by the "stripe_checkout/ip" rule above.
  throttle("moonpay_deposit/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/wallet/moonpay_deposit"
  end

  ### Throttle: on-chain entry preparation — sign-build flood backstop (prelaunch audit H5)
  # /contests/:id/prepare_entry builds a partially-signed entry TX. Cheap on
  # paper but it hits Solana RPC + holds DB locks; flood mitigation worth it.
  throttle("prepare_entry/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/contests/[^/]+/prepare_entry\z})
  end

  ### Throttle: username update — squatting / spam prevention (prelaunch audit H5)
  # On-chain set_username costs admin SOL when server-signs; throttling caps
  # spend. Phantom-cosigned path costs the user instead but still rate-limited
  # for spam control.
  throttle("update_username/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/account/update_username"
  end

  ### Response: throttled requests get 429
  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    retry_after = match_data[:period].to_i

    [
      429,
      {
        "Content-Type" => "application/json",
        "Retry-After" => retry_after.to_s
      },
      [{ error: "Too many requests. Try again later.", retry_after: retry_after }.to_json]
    ]
  end
end

# Log throttle hits — useful for tuning limits without harming legit users.
ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  Rails.logger.warn("[rack-attack] throttled match=#{req.env['rack.attack.matched']} ip=#{req.ip} path=#{req.path}")
end
