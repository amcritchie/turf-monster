# Audit log for Stripe token purchases. The minted tokens themselves live on-chain
# as EntryTokenAccount PDAs in turf-vault — see Solana::Vault#list_entry_tokens.
# This row exists for chargeback / refund forensics: we need to know which Stripe
# charge produced which on-chain mint TX(s).
class StripePurchase < ApplicationRecord
  include Sluggable

  STATUSES = %w[pending minted refunded failed].freeze

  # Token packs, keyed by a stable string id (NOT quantity) so two packs can
  # share a quantity — the standard "trio" and the test-scaffolding "test_trio"
  # both sell 3 tokens. Each pack: { quantity: tokens, price_cents: total cents }.
  PACKS = {
    "single"    => { quantity: 1, price_cents: 19_00 },
    "trio"      => { quantity: 3, price_cents: 49_00 },
    # Test scaffolding — $5 for 3 tokens. Buyable only when ENABLE_TEST_SCAFFOLDING
    # is on (see .available_packs); PACKS always lists it so a delayed webhook for
    # a test purchase still validates. DISABLE before the public launch.
    "test_trio" => { quantity: 3, price_cents: 5_00 }
  }.freeze

  # Pack ids hidden from the buy UI unless ENABLE_TEST_SCAFFOLDING is on.
  TEST_PACK_IDS = %w[test_trio].freeze

  belongs_to :user

  validates :stripe_session_id, presence: true, uniqueness: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :price_cents, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :minted,   -> { where(status: "minted") }
  scope :pending,  -> { where(status: "pending") }
  scope :refunded, -> { where(status: "refunded") }
  scope :for_session, ->(sid) { where(stripe_session_id: sid) }

  # Packs an operator/user may buy right now. PACKS always contains every pack
  # so a delayed webhook still resolves a test pack's price after the flag is off.
  def self.available_packs
    AppFlags.test_scaffolding? ? PACKS : PACKS.except(*TEST_PACK_IDS)
  end

  def self.pack(pack_id)
    PACKS.fetch(pack_id)
  end

  def self.pack_price_cents(pack_id)
    pack(pack_id).fetch(:price_cents)
  end

  def self.pack_quantity(pack_id)
    pack(pack_id).fetch(:quantity)
  end

  def self.per_token_cents(pack_id)
    config = pack(pack_id)
    config.fetch(:price_cents) / config.fetch(:quantity)
  end

  def mark_minted!(signatures)
    update!(
      status: "minted",
      mint_tx_signatures: signatures.to_json,
      minted_at: Time.current
    )
  end

  # OPSEC-036: Stripe charge.refunded — record the refund for forensics.
  def mark_refunded!(reason: nil)
    update!(status: "refunded", refunded_at: Time.current, refund_reason: reason)
  end

  # Prelaunch audit H8 (2026-05-24): the TokenPurchaseJob rescue used to
  # call `update(status: "failed")` unconditionally. If an exception fired
  # AFTER `mark_minted!` (e.g. TransactionLog.record! failing on a DB hiccup
  # post-mint), the audit row would flip from minted → failed even though
  # the on-chain mint succeeded — misleading operators investigating
  # chargebacks. Reload before writing, and refuse to downgrade a minted row.
  def mark_failed_unless_minted!
    reload
    return if status == "minted"
    update!(status: "failed")
  end

  def tx_signatures
    return [] if mint_tx_signatures.blank?
    JSON.parse(mint_tx_signatures)
  rescue JSON::ParserError
    []
  end

  private

  def name_slug
    "stripe_#{stripe_session_id[0, 16]}_#{SecureRandom.hex(2)}"
  end
end
