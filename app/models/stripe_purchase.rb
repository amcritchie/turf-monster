# Audit log for Stripe token purchases. The minted tokens themselves live on-chain
# as EntryTokenAccount PDAs in turf-vault — see Solana::Vault#list_entry_tokens.
# This row exists for chargeback / refund forensics: we need to know which Stripe
# charge produced which on-chain mint TX(s).
class StripePurchase < ApplicationRecord
  include Sluggable

  STATUSES = %w[pending minted refunded failed].freeze
  PACKS = { 1 => 1900, 3 => 4900 }.freeze # tokens => cents, matches turf-vault EntryTokenAccount minting

  belongs_to :user

  validates :stripe_session_id, presence: true, uniqueness: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :price_cents, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :minted,   -> { where(status: "minted") }
  scope :pending,  -> { where(status: "pending") }
  scope :refunded, -> { where(status: "refunded") }
  scope :for_session, ->(sid) { where(stripe_session_id: sid) }

  def self.pack_price_cents(quantity)
    PACKS.fetch(quantity)
  end

  def self.per_token_cents(quantity)
    pack_price_cents(quantity) / quantity
  end

  def mark_minted!(signatures)
    update!(
      status: "minted",
      mint_tx_signatures: signatures.to_json,
      minted_at: Time.current
    )
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
