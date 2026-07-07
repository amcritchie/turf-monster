class NflTeamTotalProjection < ApplicationRecord
  belongs_to :slate, optional: true
  belongs_to :game, foreign_key: :game_slug, primary_key: :slug
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug
  belongs_to :opponent_team, class_name: "Team", foreign_key: :opponent_team_slug, primary_key: :slug
  belongs_to :favorite_team, class_name: "Team", foreign_key: :favorite_team_slug, primary_key: :slug

  validates :year, numericality: { only_integer: true, greater_than_or_equal_to: 2026 }
  validates :week, numericality: { only_integer: true, in: 1..18 }
  validates :home, inclusion: { in: [true, false] }
  validates :game_slug, :team_slug, :opponent_team_slug, :favorite_team_slug, :source, :cached_at, presence: true
  validates :expected_points, :game_total, numericality: { greater_than: 0 }
  validates :home_spread, :favorite_spread, numericality: true
  validates :team_slug, uniqueness: { scope: [:year, :week, :game_slug] }

  scope :for_year, ->(year) { where(year: year) }
  scope :for_week, ->(week) { where(week: week) }
  scope :for_team, ->(team_or_slug) { where(team_slug: team_or_slug.respond_to?(:slug) ? team_or_slug.slug : team_or_slug) }
  scope :ordered, -> { order(:week, :game_slug, :home) }
  scope :highest_first, -> { order(expected_points: :desc, team_slug: :asc) }

  def spread_label
    return "PK" if favorite_spread.to_d.zero?

    "#{favorite_team.short_name || favorite_team.name} #{format('%+.1f', favorite_spread)}"
  end
end
