# Request- and job-scoped context. ActiveSupport::CurrentAttributes auto-resets
# between requests (Rack middleware) and between Sidekiq jobs (ActiveJob middleware).
#
# Read by OutboundRequestLogger.record! to attribute Stripe / Solana RPC calls
# back to the originating StripePurchase + user without threading params through
# every layer.
#
#   - `Current.user`            — set by ApplicationController#set_current_context
#   - `Current.outbound_source` — set by jobs/services that own a domain object
#     (e.g. TokenPurchaseJob sets it to the StripePurchase being processed)
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :outbound_source

  # Per-request memo for the on-chain VaultState read used by the admin
  # dropdown's "Vault Init" / "Vault State (PAUSED)" badges. Both badges
  # answer questions about the same account; without sharing they fire two
  # serial getAccountInfo RPCs on every admin page render.
  # `_fetched` is a separate flag so we can memoize a legitimate `nil`
  # (vault not yet initialized) without re-fetching.
  attribute :vault_state, :vault_state_fetched
end
