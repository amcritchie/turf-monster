class PendingTransaction < ApplicationRecord
  include Sluggable

  belongs_to :target, polymorphic: true, optional: true

  validates :tx_type, presence: true
  validates :serialized_tx, presence: true
  validates :status, inclusion: { in: %w[pending submitted confirmed expired failed] }

  # BL4 (Stage 3 audit) bug fix: name_slug includes `id`, which is nil during
  # Sluggable's before_save. Without intervention, every row got slug "ptx-"
  # → unique index meant only ONE PendingTransaction could exist at a time
  # (treasury blocker). Use tmp-unique slug during INSERT, then overwrite
  # with canonical "ptx-<id>" after_create.
  after_create :update_slug_with_id

  scope :pending, -> { where(status: "pending") }
  scope :confirmed, -> { where(status: "confirmed") }

  def name_slug
    id ? "ptx-#{id}" : "ptx-tmp-#{SecureRandom.hex(8)}"
  end

  def parsed_metadata
    metadata.present? ? JSON.parse(metadata) : {}
  end

  def pending?
    status == "pending"
  end

  def confirmed?
    status == "confirmed"
  end

  private

  def update_slug_with_id
    update_column(:slug, "ptx-#{id}")
  end
end
