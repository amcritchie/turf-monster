class GeoSetting < ApplicationRecord
  include Sluggable

  validates :app_name, presence: true, uniqueness: true

  # CA added 2026-06 (underwriting compliance): the 2025 California AG opinion
  # treats paid fantasy contests as unlawful, so CA is excluded alongside the
  # legacy DFS-prohibited list. NOTE: seeds use find_or_create_by!, so an
  # EXISTING GeoSetting row (prod) does NOT pick this up automatically — the
  # operator must add CA via /admin/geo before relying on it.
  DEFAULT_BANNED_STATES = %w[WA ID MT LA AZ HI NV CA].freeze

  def self.current
    find_or_initialize_by(app_name: Studio.app_name)
  end

  # The published exclusion list — /state-eligibility and the Terms of
  # Service render THIS, the same list enforcement reads, so the public
  # policy can never drift from the geo gate. Falls back to the defaults
  # when no row has been provisioned yet.
  def self.effective_banned_states
    setting = current
    states = setting.persisted? ? Array(setting.banned_states) : DEFAULT_BANNED_STATES
    states.map(&:to_s).uniq.sort
  end

  def self.blocked?(state_code)
    return false if state_code.blank?
    setting = current
    setting.persisted? && setting.enabled? && setting.banned_states.include?(state_code)
  end

  def name_slug
    "geo-#{app_name.parameterize}"
  end
end
