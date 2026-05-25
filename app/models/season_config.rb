# Singleton pointer to the on-chain Season currently in effect for this app.
# The Season itself lives on-chain (turf-vault v0.11.0+) as a `Season` PDA;
# this row just tracks which season_id Rails should pass into entry instructions.
#
# Also carries the "main contest" pointer used as the default fallback target
# across the app — root redirect, /account referral widget, faucet CTA. The
# main contest is admin-set via /admin/site_config; when unset or the chosen
# contest has settled, SeasonConfig.main_contest falls back to the most
# recently created open contest.
class SeasonConfig < ApplicationRecord
  include Sluggable

  belongs_to :main_contest, class_name: "Contest", optional: true

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

  # Resolve the "main contest" used by anything that needs a default contest
  # target — root redirect, share widget, faucet CTA, etc. Returns the admin's
  # explicit pick when it's still open; otherwise falls back to the most
  # recently created open contest. Returns nil if nothing is open at all.
  def self.main_contest
    explicit = current.main_contest
    return explicit if explicit&.open?
    Contest.where(status: :open).order(created_at: :desc).first
  end

  # The unfiltered admin choice — distinct from main_contest, which masks the
  # explicit pick when it's not currently open. Used by the admin form.
  def self.main_contest_explicit
    current.main_contest
  end

  def self.set_main_contest!(contest_or_id)
    id = contest_or_id.respond_to?(:id) ? contest_or_id.id : contest_or_id
    current.update!(main_contest_id: id.presence)
  end

  private

  def name_slug
    "season-config"
  end
end
