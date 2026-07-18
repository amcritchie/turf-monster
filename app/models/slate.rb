class Slate < ApplicationRecord
  include Sluggable

  FORMULA_DEFAULTS = {
    formula_a: 1.65, formula_line_exp: 1.24, formula_prob_exp: 1.18,
    formula_mult_base: 1.0, formula_mult_scale: 2.0,
    formula_goal_base: 0.2, formula_goal_scale: 4.3
  }.freeze

  FORMULA_COLUMNS = FORMULA_DEFAULTS.keys.freeze

  has_many :slate_matchups, dependent: :destroy
  has_many :contests
  has_many :nfl_team_total_projections, dependent: :nullify

  validates :name, presence: true

  def self.default_record
    find_by(name: "Default")
  end

  def resolved_formula
    defaults = self.class.default_record
    FORMULA_DEFAULTS.each_with_object({}) do |(key, hardcoded), hash|
      hash[key] = read_attribute(key) || (defaults&.id != id ? defaults&.read_attribute(key) : nil) || hardcoded
    end
  end

  # ─── Team-level view of the slate ───────────────────────────────────
  #
  # A Slate is a pool of GAMES. A team appears once per game it plays here, so a
  # one-week slate has one row per team and a "Weeks 1-3" slate has three. The
  # PICKABLE unit is the team, and everything a player is priced on — expected
  # points, rank, multiplier — is that team's SUM across its games in the slate.
  #
  # A one-week slate is the degenerate case: summing one game is that game.

  # { team_slug => [matchup, ...] }, each team's games in kickoff order.
  def matchups_by_team
    slate_matchups.includes(:team, :opponent_team, :game)
                  .group_by(&:team_slug)
                  .transform_values { |matchups| matchups.sort_by { |m| m.game&.kickoff_at || Time.at(0) } }
  end

  # { team_slug => summed dk_goals_expectation }
  def expected_points_by_team
    matchups_by_team.transform_values do |matchups|
      matchups.sum { |matchup| matchup.dk_goals_expectation.to_f }
    end
  end

  # { team_slug => { rank:, turf_score: } }, ranked by SUMMED expected points
  # (highest expectation = rank 1 = lowest multiplier).
  #
  # The tie-break — earliest kickoff, then team name — deliberately mirrors the
  # per-row ordering this replaced, so a ONE-week slate ranks identically to
  # before. Changing it would silently re-price tied teams on every existing
  # slate. (NFL games currently carry no kickoff_at at all, so ties in practice
  # fall straight through to the name.)
  def team_rankings
    by_team = matchups_by_team
    return {} if by_team.empty?

    ranked = by_team.sort_by do |_team_slug, matchups|
      [
        -matchups.sum { |matchup| matchup.dk_goals_expectation.to_f },
        matchups.filter_map { |matchup| matchup.game&.kickoff_at }.min || Time.at(0),
        matchups.first.team.name
      ]
    end

    ranked.each_with_index.to_h do |(team_slug, _matchups), index|
      rank = index + 1
      [team_slug, { rank: rank, turf_score: SlateMatchup.turf_score_for(rank, ranked.size) }]
    end
  end

  # One row per TEAM for the slate page and the ranking admin: the team, the
  # games it plays here, its SUMMED expected points, and the rank + multiplier
  # those earn. Ordered by rank.
  TeamRow = Data.define(:team_slug, :team, :matchups, :expected_points, :rank, :turf_score)

  def team_rows
    rankings = team_rankings

    rows = matchups_by_team.map do |team_slug, matchups|
      ranking = rankings[team_slug] || {}
      TeamRow.new(
        team_slug: team_slug,
        team: matchups.first.team,
        matchups: matchups,
        expected_points: matchups.sum { |matchup| matchup.dk_goals_expectation.to_f },
        rank: ranking[:rank],
        turf_score: ranking[:turf_score]
      )
    end

    rows.sort_by { |row| row.rank || Float::INFINITY }
  end

  # True when any team plays more than once here — i.e. the slate spans weeks.
  def multi_game_per_team?
    matchups_by_team.any? { |_team_slug, matchups| matchups.size > 1 }
  end

  # How many games a team plays in this slate (the span length).
  def games_per_team
    matchups_by_team.values.map(&:size).max.to_i
  end

  def name_slug
    name.parameterize
  end

  def first_game
    slate_matchups.includes(:game).map(&:game).compact.uniq.select(&:kickoff_at).min_by(&:kickoff_at)
  end

  def first_game_starts_at
    first_game&.kickoff_at
  end
end
