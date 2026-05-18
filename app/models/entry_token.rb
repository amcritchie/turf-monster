class EntryToken < ApplicationRecord
  belongs_to :user
  belongs_to :entry, optional: true

  STATUSES = %w[purchased spent refunded expired].freeze
  SOURCES  = %w[stripe moonpay dev comp promo].freeze

  # Pack pricing — see Contest::FORMATS, all tiers $19 entry fee.
  # Per-token price for chargeback accounting: 3-pack tokens cost $16.33 each.
  PACKS = {
    1 => 19_00,
    3 => 49_00
  }.freeze

  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :price_cents, numericality: { greater_than_or_equal_to: 0 }

  scope :purchased, -> { where(status: "purchased") }
  scope :spent,     -> { where(status: "spent") }
  scope :refunded,  -> { where(status: "refunded") }
  scope :for_source_ref, ->(ref) { where(source_ref: ref) }

  def self.pack_price_cents(quantity)
    PACKS[quantity] or raise ArgumentError, "Unknown pack quantity: #{quantity}"
  end

  def self.per_token_cents(quantity)
    pack_price_cents(quantity) / quantity
  end

  def self.purchase!(user:, quantity:, source:, source_ref: nil)
    per_token = per_token_cents(quantity)
    transaction do
      quantity.times.map do
        create!(user: user, status: "purchased", source: source, source_ref: source_ref, price_cents: per_token)
      end
    end
  end

  def spend!(entry:)
    raise "Token already spent" unless status == "purchased"
    update!(status: "spent", entry: entry, spent_at: Time.current)
  end
end
