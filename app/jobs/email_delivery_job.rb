# Sends a recorded EmailDelivery and flips its `sent` flag. Re-raises on failure
# so Sidekiq's retry backoff handles a transient mail-server outage; the row
# stays `sent: false` until a run succeeds.
class EmailDeliveryJob < ApplicationJob
  queue_as :mailers

  def perform(id)
    EmailDelivery.find_by(id: id)&.deliver_now!
  end
end
