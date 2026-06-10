module Cdp
  # Mints the single-use CDP session token and hands the Coinbase-hosted
  # widget URL back to the client:
  #
  #   POST /cdp/onramp_sessions  → { url: } (buy USDC into the user's wallet)
  #   POST /cdp/offramp_sessions → { url: } (cash out USDC to fiat)
  #
  # See docs/CDP_RAMP_INTEGRATION.md §8. Security posture (Coinbase explicitly
  # holds the developer liable for a misused session-token mint endpoint):
  #   - require_authentication (engine default before_action; the app override
  #     returns a clean JSON 401 for authedFetch)
  #   - geo gates: the state blocklist (require_geo_allowed) + the Cdp::Catalog
  #     country/subdivision availability check (fails closed)
  #   - per-user rack-attack throttle "cdp_sessions/user" (config/initializers/
  #     rack_attack.rb)
  #   - NO CORS headers, ever — these are same-origin authedFetch POSTs; never
  #     add Access-Control-Allow-Origin here.
  #
  # Tokens are single-use with a 5-minute TTL — minted at click time, never at
  # page render, never cached (§5).
  class RampSessionsController < BaseController
    # B4 / OPSEC-048: ramp sessions move money — frozen accounts can't open them.
    before_action :require_unfrozen_account
    before_action :require_geo_allowed

    def create_onramp
      create_session(:onramp)
    end

    def create_offramp
      create_session(:offramp)
    end

    private

    def create_session(direction)
      address, mode = wallet_for(direction)
      if address.blank?
        return render json: { error: "Connect a wallet first." }, status: :unprocessable_entity
      end

      unless ramp_available?(direction)
        return render json: { error: unavailable_message(direction) }, status: :unprocessable_entity
      end

      # Row first (status: initiated), so partner_user_ref exists before any
      # CDP call and a mint failure leaves a diagnosable record behind.
      ramp = nil
      rescue_and_log(target: current_user) do
        ramp = CdpRampTransaction.create!(
          user: current_user,
          direction: direction,
          wallet_address: address,
          wallet_mode: mode
        )
      end

      rescue_and_log(target: ramp, parent: current_user) do
        token = SessionTokenService.new.mint(address: address, client_ip: request.remote_ip)
        url = build_url(direction, ramp, token)
        ramp.mark_token_minted!
        render json: { url: url }
      end
    rescue Cdp::Client::RateLimitError
      render json: { error: "Coinbase is busy right now — please try again in a moment." },
             status: :too_many_requests
    rescue Cdp::Client::Error
      render json: { error: "Couldn't start a Coinbase session. Please try again." },
             status: :bad_gateway
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # §5 address selection:
    #   onramp  → DESTINATION wallet: User#solana_address (web3 preferred,
    #             web2 fallback)
    #   offramp → the SOURCE wallet that will sign the post-widget send: web3
    #             when this session can produce Phantom signatures
    #             (wallet_context.web3?), else the managed web2 wallet the
    #             server signs with.
    def wallet_for(direction)
      user = current_user
      if direction == :onramp
        address = user.solana_address
        mode = address.present? && address == user.web3_solana_address ? :web3 : :web2
        [address, mode]
      elsif wallet_context.web3? && user.web3_solana_address.present?
        [user.web3_solana_address, :web3]
      else
        [user.web2_solana_address, :web2]
      end
    end

    # §13 catalog gate — FAILS CLOSED: a Coinbase outage or an undetected US
    # state (subdivision required for country=US) yields unavailable, never a
    # 500. One Catalog per request (per-instance memo over Rails.cache).
    def ramp_available?(direction)
      catalog = Catalog.new
      if direction == :onramp
        catalog.onramp_available?(country: geo_country, subdivision: geo_state)
      else
        catalog.offramp_available?(country: geo_country, subdivision: geo_state)
      end
    end

    def unavailable_message(direction)
      verb = direction == :onramp ? "Buying USDC" : "Cashing out"
      "#{verb} via Coinbase isn't available in your region yet."
    end

    def build_url(direction, ramp, token)
      if direction == :onramp
        OnrampUrl.build(
          session_token: token,
          partner_user_ref: ramp.partner_user_ref,
          redirect_url: cdp_onramp_return_url
        )
      else
        OfframpUrl.build(
          session_token: token,
          partner_user_ref: ramp.partner_user_ref,
          redirect_url: cdp_offramp_return_url
        )
      end
    end
  end
end
