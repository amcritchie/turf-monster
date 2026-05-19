# Audit log of every outbound HTTP / JSON-RPC call to a third-party service.
# Populated by OutboundRequestLogger via the Stripe instrumentation hook + the
# Solana::Client prepend in config/initializers/outbound_request_hooks.rb.
#
# Immutable: created once per call, never updated. The retention sweeper job
# trims the table on a schedule (90d for success, 180d for errors).
class OutboundRequest < ApplicationRecord
  self.record_timestamps = false # we manage created_at manually, no updated_at

  belongs_to :source, polymorphic: true, optional: true
  belongs_to :user,                       optional: true

  SERVICES = %w[stripe solana_rpc moonpay].freeze

  validates :service, presence: true

  before_create :ensure_created_at

  scope :recent,      -> { order(created_at: :desc) }
  scope :for_service, ->(svc) { where(service: svc) }
  scope :failed,      -> { where("error_class IS NOT NULL OR status_code >= 400") }
  scope :successful,  -> { where(error_class: nil).where("status_code IS NULL OR status_code < 400") }

  def failed?
    error_class.present? || (status_code.present? && status_code >= 400)
  end

  def successful?
    !failed?
  end

  private

  def ensure_created_at
    self.created_at ||= Time.current
  end
end
