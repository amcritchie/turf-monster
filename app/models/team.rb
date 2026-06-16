class Team < ApplicationRecord
  include Sluggable

  belongs_to :home_arena, class_name: "Arena", foreign_key: :home_arena_slug, primary_key: :slug, optional: true

  has_many :players, foreign_key: :team_slug, primary_key: :slug
  has_many :home_games, class_name: "Game", foreign_key: :home_team_slug, primary_key: :slug
  has_many :away_games, class_name: "Game", foreign_key: :away_team_slug, primary_key: :slug

  validates :name, presence: true

  before_validation :set_default_mascot, if: -> { self[:mascot].blank? && name.present? }

  scope :nfl, -> { where(league: "nfl") }
  scope :fifa, -> { where(league: "fifa") }
  scope :football, -> { where(sport: "football") }
  scope :soccer, -> { where(sport: "soccer") }

  def mascot
    self[:mascot].presence || derived_mascot
  end

  def name_slug
    name.parameterize
  end

  private

  def set_default_mascot
    self[:mascot] = derived_mascot
  end

  def derived_mascot
    return name if location.blank?

    name.sub(/\A#{Regexp.escape(location)}\s*/, "").strip.presence || name
  end
end
