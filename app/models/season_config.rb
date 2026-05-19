# Singleton pointer to the on-chain Season currently in effect for this app.
# The Season itself lives on-chain (turf-vault v0.11.0+) as a `Season` PDA;
# this row just tracks which season_id Rails should pass into entry instructions.
class SeasonConfig < ApplicationRecord
  include Sluggable

  validates :current_season_id, numericality: { greater_than_or_equal_to: 0 }

  def self.current
    find_or_create_by(slug: "season-config")
  end

  def self.current_season_id
    current.current_season_id
  end

  def self.set_current!(season_id)
    current.update!(current_season_id: season_id)
  end

  private

  def name_slug
    "season-config"
  end
end
