# One row per Coinbase CDP hosted-widget session (onramp = buy USDC into the
# user's wallet, offramp = sell USDC to fiat). Created BEFORE the session token
# is minted so partner_user_ref ("tm-<user_id>-<id>") exists to correlate the
# widget session with the Transaction Status API + (phase 2) webhooks.
#
# Two status fields, deliberately separate:
#   - status      — OUR local lifecycle (see STATUSES below)
#   - cdp_status  — the raw CDP status string, stored verbatim (the API enum
#                   conflicts between doc pages — handle unknown values
#                   defensively, never case-exhaustively)
#
# coinbase_transaction_id is the idempotency key for poll-job/webhook upserts.
# See docs/CDP_RAMP_INTEGRATION.md §9.
class CdpRampTransaction < ApplicationRecord
  # partnerUserRef must be < 50 chars in the hosted URLs + status APIs.
  PARTNER_USER_REF_MAX = 49

  belongs_to :user

  # Local lifecycle:
  #   initiated    — row created, nothing minted yet
  #   token_minted — session token minted, hosted URL handed to the client
  #   returned     — user hit our redirectUrl (UX signal only — NEVER confirmation)
  #   cdp_created  — offramp: CDP transaction exists (TRANSACTION_STATUS_CREATED);
  #                  gates our USDC send within the 30-minute window
  #   sending      — offramp: our USDC transfer to to_address is in flight
  #   sent         — offramp: sent_signature recorded, awaiting CDP settlement
  #   success      — terminal: CDP reports the ramp completed
  #   failed       — terminal: CDP reports failure (incl. late offramp sends)
  #   expired      — terminal: session/cashout window lapsed before completion
  #   abandoned    — terminal: user never came back (stale sweep)
  enum :status, {
    initiated:    "initiated",
    token_minted: "token_minted",
    returned:     "returned",
    cdp_created:  "cdp_created",
    sending:      "sending",
    sent:         "sent",
    success:      "success",
    failed:       "failed",
    expired:      "expired",
    abandoned:    "abandoned"
  }, default: "initiated"

  enum :direction, { onramp: "onramp", offramp: "offramp" }

  # web2 = managed wallet (server can sign the offramp send),
  # web3 = Phantom (client signs).
  enum :wallet_mode, { web2: "web2", web3: "web3" }, prefix: :wallet

  validates :direction, presence: true
  validates :status, presence: true
  validates :wallet_address, presence: true
  validates :wallet_mode, presence: true
  validates :asset, presence: true
  validates :network, presence: true
  validates :partner_user_ref,
            uniqueness: true,
            length: { maximum: PARTNER_USER_REF_MAX },
            allow_nil: true
  validates :coinbase_transaction_id, uniqueness: true, allow_nil: true

  # Needs the row id, so it can't be a before_validation (same pattern as
  # Entry's id-bearing slug).
  after_create :assign_partner_user_ref

  scope :recent, -> { order(created_at: :desc) }

  def terminal?
    success? || failed? || expired? || abandoned?
  end

  def sell_amount
    return nil if sell_amount_value.nil?
    BigDecimal(sell_amount_value.to_s)
  end

  private

  def assign_partner_user_ref
    return if partner_user_ref.present?
    update_column(:partner_user_ref, "tm-#{user_id}-#{id}")
  end
end
