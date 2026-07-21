class SlateMatchup < ApplicationRecord
  include Sluggable

  belongs_to :slate
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug
  belongs_to :opponent_team, class_name: "Team", foreign_key: :opponent_team_slug, primary_key: :slug, optional: true
  belongs_to :game, foreign_key: :game_slug, primary_key: :slug, optional: true

  has_many :selections, dependent: :destroy

  # A team appears once per GAME it plays in the slate — a "Weeks 1-3" slate
  # holds three rows per team. Scoped on game_slug rather than the slate alone,
  # which is what used to cap a team at one appearance.
  #
  # This also covers what the DB index can't: game_slug is nullable and PG 14
  # predates NULLS NOT DISTINCT, so the index treats NULL rows as all distinct.
  # Rails generates `game_slug IS NULL` here and catches that case.
  validates :team_slug, uniqueness: { scope: [:slate_id, :game_slug] }

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

  # V3 "anchored" DK Score (restored verbatim from 405f902; dropped with the
  # odds columns in 1fd6c50): integer-anchored line + implied-probability
  # spread, floored at zero. Renders on /slates/formula_report.
  def self.dk_score_for(line, over_odds)
    return nil unless line && over_odds

    prob = if over_odds < 0
      over_odds.abs.to_f / (over_odds.abs + 100)
    else
      100.0 / (over_odds + 100)
    end
    [(line - 0.5) + (prob - 0.5) * 3, 0].max.round(2)
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

  # On a SPAN slate a team has several rows, and two of them can share an
  # opponent (a division rival played twice inside the span), which made this
  # slug collide against the unique index and refuse the row outright. Qualify it
  # by week in that case.
  #
  # Deliberately scoped to span slates: Sluggable rewrites the slug on EVERY
  # save, so appending unconditionally would churn every existing weekly
  # matchup's slug for no gain.
  def name_slug
    base = "#{slate.slug}-#{team_slug}-vs-#{opponent_team_slug}"
    return base unless week.present? && slate&.week_range&.size.to_i > 1

    "#{base}-wk#{week}"
  end
end
