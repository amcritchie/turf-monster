class Team < ApplicationRecord
  include Sluggable

  belongs_to :home_arena, class_name: "Arena", foreign_key: :home_arena_slug, primary_key: :slug, optional: true

  has_many :players, foreign_key: :team_slug, primary_key: :slug
  has_many :home_games, class_name: "Game", foreign_key: :home_team_slug, primary_key: :slug
  has_many :away_games, class_name: "Game", foreign_key: :away_team_slug, primary_key: :slug

  validates :name, presence: true

  scope :nfl, -> { where(league: "nfl") }
  scope :fifa, -> { where(league: "fifa") }
  scope :football, -> { where(sport: "football") }
  scope :soccer, -> { where(sport: "soccer") }

  def mascot
    return name if location.blank?

    name.sub(/\A#{Regexp.escape(location)}\s*/, "").strip
  end

  def name_slug
    name.parameterize
  end
end
