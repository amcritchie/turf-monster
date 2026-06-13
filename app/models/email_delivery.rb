# Outbox + audit log for every transactional email. `EmailDelivery.deliver(...)`
# records the intent durably, then enqueues EmailDeliveryJob to actually send and
# flip `sent`. A mail-server outage leaves rows `sent: false` — the job retries
# via Sidekiq, and `EmailDelivery.resend_unsent!` re-enqueues any stragglers so
# we can pick up exactly where we left off.
class EmailDelivery < ApplicationRecord
  belongs_to :user, optional: true

  scope :unsent, -> { where(sent: false) }
  scope :recent, -> { order(created_at: :desc) }

  # Drop-in for `Mailer.action(*args, **kwargs).deliver_later`, but durable: the
  # row exists before the send is ever attempted.
  def self.deliver(mailer, action, *args, to:, user: nil, **kwargs)
    record = create!(
      mailer:    mailer.to_s,
      action:    action.to_s,
      email_key: "#{mailer}##{action}",
      to:        to.to_s,
      user:      user,
      args:      ActiveJob::Arguments.serialize(args),
      kwargs:    ActiveJob::Arguments.serialize([kwargs]).first
    )
    EmailDeliveryJob.perform_later(record.id)
    record
  end

  # Rebuild the mailer from the stored args + deliver. Marks `sent` on success;
  # on failure leaves the row unsent (with the error) and re-raises so Sidekiq
  # retries.
  def deliver_now!
    return if sent?

    pos = ActiveJob::Arguments.deserialize(args)
    kw  = ActiveJob::Arguments.deserialize([kwargs]).first.symbolize_keys
    mailer.constantize.public_send(action, *pos, **kw).deliver_now
    update!(sent: true, sent_at: Time.current, error: nil)
  rescue StandardError => e
    update(error: e.message.to_s.first(500))
    raise
  end

  # Operator recovery after a mail-server outage — re-enqueue every unsent row.
  def self.resend_unsent!
    unsent.find_each { |d| EmailDeliveryJob.perform_later(d.id) }
  end
end
