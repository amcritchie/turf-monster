class SurvivorRound < ApplicationRecord
  include Sluggable

  STAGES = %w[group knockout].freeze

  has_many :games, dependent: :nullify
  has_many :survivor_picks, dependent: :destroy

  enum :status, { upcoming: "upcoming", locked: "locked", completed: "completed" }

  validates :number, presence: true, uniqueness: true
  validates :name, presence: true
  validates :stage, inclusion: { in: STAGES }

  scope :ordered, -> { order(:number) }

  # The round currently in focus — the earliest one not yet graded.
  def self.current
    ordered.where.not(status: "completed").first
  end

  def group_stage?
    stage == "group"
  end

  def knockout?
    stage == "knockout"
  end

  # True once picks can no longer be submitted for this round.
  def picks_locked?
    return true if locked? || completed?
    picks_lock_at.present? && Time.current >= picks_lock_at
  end

  def name_slug
    name.parameterize
  end
end
