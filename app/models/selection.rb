class Selection < ApplicationRecord
  include Sluggable

  belongs_to :entry
  belongs_to :slate_matchup

  validates :slate_matchup_id, uniqueness: { scope: :entry_id }

  # Points for one pick.
  #
  # Single week: goals × that matchup's turf_score, unchanged.
  #
  # Multi-week: the picked TEAM rides every week, so this is the team's TOTAL
  # goals across the span × ONE span multiplier (Contest#span_turf_scores),
  # which is itself derived from the team's expected points summed over the same
  # weeks. Keeping it to a single multiplier is what makes the format scale from
  # one opponent to three — a player reads exactly the same "points per goal"
  # number they read on a one-week contest.
  #
  # Weeks with no result yet (and bye weeks, which have no matchup at all)
  # contribute no goals, so the leaderboard accrues live as each week completes.
  # With NO week scored yet, points are left untouched — matching single-week.
  def compute_points!
    contest = entry.contest

    if contest&.multi_week?
      scored = scoring_matchups.select { |matchup| matchup.goals.present? }
      return if scored.empty?

      multiplier = contest.span_turf_score_for(slate_matchup.team_slug)
      return if multiplier.blank?

      update!(points: scored.sum(&:goals) * multiplier)
    else
      return unless slate_matchup.goals.present? && slate_matchup.turf_score.present?

      update!(points: slate_matchup.goals * slate_matchup.turf_score)
    end
  end

  def name_slug
    "#{entry.slug}-#{slate_matchup.team_slug}"
  end

  # Per-week breakdown for the leaderboard / board UI: [[slate, matchup], ...]
  # in week order. Single-week contests return their one pair.
  def weekly_breakdown
    contest = entry.contest
    return [[slate_matchup.slate, slate_matchup]] unless contest&.multi_week?

    by_slate = contest.matchups_for_team(slate_matchup.team_slug).index_by(&:slate_id)
    contest.week_slates.map { |slate| [slate, by_slate[slate.id]] }
  end

  private

  # Single-week: the picked matchup itself. Multi-week: that team's matchup in
  # every week of the contest's span.
  def scoring_matchups
    contest = entry.contest
    return [slate_matchup] unless contest&.multi_week?

    contest.matchups_for_team(slate_matchup.team_slug).to_a
  end
end
