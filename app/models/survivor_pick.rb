class SurvivorPick < ApplicationRecord
  include Sluggable

  belongs_to :entry
  belongs_to :survivor_round
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug

  enum :result, { pending: "pending", survived: "survived", eliminated: "eliminated" }

  # One pick per entry per round.
  validates :survivor_round_id, uniqueness: { scope: :entry_id }
  # No team reuse — a team may be picked at most once across the tournament.
  validates :team_slug, uniqueness: { scope: :entry_id }

  def name_slug
    "#{entry.slug}-round-#{survivor_round.number}"
  end
end
