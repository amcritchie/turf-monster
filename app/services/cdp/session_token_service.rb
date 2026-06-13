module Cdp
  # Mints the hosted-widget session token — the shared mint for BOTH onramp
  # and offramp URLs (POST /onramp/v1/token is the only documented path for
  # offramp). See docs/CDP_RAMP_INTEGRATION.md §5.
  #
  # The token is SINGLE-USE and expires after 5 minutes — mint at click time
  # (AJAX), never at page render, never cache.
  #
  # Address semantics:
  #   onramp  → DESTINATION wallet (user.solana_address: web3 preferred, web2 fallback)
  #   offramp → SOURCE of the funds being sold (the wallet that will sign the
  #             send: web3_solana_address for Phantom, web2_solana_address for managed)
  #
  # clientIp is treated as required (docs conflict — see spec open question 1);
  # request.remote_ip is the only realistic source behind Heroku's router.
  class SessionTokenService
    PATH = "/onramp/v1/token".freeze

    def initialize(client: Cdp::Client.new)
      @client = client
    end

    # Returns the session token string. Raises Cdp::Client::Error subclasses on
    # API failure, or ApiError if the response carries no token.
    def mint(address:, client_ip:, assets: ["USDC"], blockchains: ["solana"])
      raise ArgumentError, "address is required" if address.blank?

      # Request body is camelCase by design (clientIp) — see Cdp::Client.
      body = {
        addresses: [{ address: address, blockchains: blockchains }],
        assets: assets,
        clientIp: client_ip
      }
      response = @client.post(PATH, body)
      token = response.is_a?(Hash) ? response["token"] : nil
      if token.blank?
        raise Cdp::Client::ApiError.new("CDP session token missing from response")
      end
      token
    end
  end
end
