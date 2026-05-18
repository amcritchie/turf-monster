class TransactionLog < ApplicationRecord
  after_create :update_slug_with_id

  belongs_to :user
  belongs_to :source, polymorphic: true, optional: true

  validates :transaction_type, presence: true
  validates :amount_cents, presence: true, numericality: { greater_than: 0 }
  validates :direction, presence: true, inclusion: { in: %w[credit debit] }
  validates :status, presence: true, inclusion: { in: %w[completed pending failed approved] }

  scope :credits, -> { where(direction: "credit") }
  scope :debits, -> { where(direction: "debit") }
  scope :pending, -> { where(status: "pending") }
  scope :completed, -> { where(status: "completed") }
  scope :by_type, ->(type) { where(transaction_type: type) }

  TYPES = %w[deposit withdrawal entry_fee payout admin_credit faucet token_purchase].freeze

  def self.record!(user:, type:, amount_cents:, direction:, source: nil, description: nil, status: "completed", onchain_tx: nil, metadata: {})
    create!(
      user: user,
      transaction_type: type,
      amount_cents: amount_cents,
      direction: direction,
      balance_after_cents: nil,
      source: source,
      source_name: source&.slug,
      description: description,
      status: status,
      onchain_tx: onchain_tx,
      metadata: metadata
    )
  end

  def credit?
    direction == "credit"
  end

  def debit?
    direction == "debit"
  end

  def amount_dollars
    amount_cents / 100.0
  end

  def balance_after_dollars
    return nil unless balance_after_cents
    balance_after_cents / 100.0
  end

  private

  def update_slug_with_id
    update_column(:slug, name_slug)
  end

  public

  def to_param
    slug
  end

  def name_slug
    "txn-#{id}"
  end
end
