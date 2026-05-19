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
end
