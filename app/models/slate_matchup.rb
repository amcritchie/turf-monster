class SlateMatchup < ApplicationRecord
  include Sluggable

  belongs_to :slate
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug
  belongs_to :opponent_team, class_name: "Team", foreign_key: :opponent_team_slug, primary_key: :slug, optional: true
  belongs_to :game, foreign_key: :game_slug, primary_key: :slug, optional: true

  has_many :selections, dependent: :destroy

  validates :team_slug, uniqueness: { scope: :slate_id }

  scope :ranked, -> { order(:rank) }
  scope :pending, -> { where(status: "pending") }
  scope :completed, -> { where(status: "completed") }

  # ─── Centralized Formulas ───────────────────────────────────
  # JS mirrors live in show.html.erb and formula_report.html.erb

  # Hardcoded fallback (no per-slate config available). Mirrors the
  # Slate::FORMULA_DEFAULTS turf-score defaults: base 1.0, scale 2.0.
  # Per-slate overrides live on Slate.formula_mult_base / mult_scale and
  # are resolved at render time via Slate#resolved_formula; the JS
  # mirrors in slates/show.html.erb + slates/formula_report.html.erb
  # use those resolved values.
  def self.turf_score_for(rank, n)
    (1.0 + 2.0 * Math.log(rank) / Math.log(n)).round(1)
  end

  def self.goals_distribution_for(rank, n)
    (0.2 + 4.3 * Math.log(n.to_f / rank) / Math.log(n)).round(2)
  end

  # ─── Instance Methods ───────────────────────────────────────

  def locked?
    game&.kickoff_at.present? && game.kickoff_at <= Time.current
  end

  def compute_turf_score!(n = nil)
    return unless rank.present?
    n ||= slate.slate_matchups.count
    update!(turf_score: self.class.turf_score_for(rank, n))
  end

  def name_slug
    "#{team_slug}-vs-#{opponent_team_slug}"
  end
end
