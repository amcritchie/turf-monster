class Selection < ApplicationRecord
  include Sluggable

  belongs_to :entry
  belongs_to :slate_matchup

  validates :slate_matchup_id, uniqueness: { scope: :entry_id }

  # Points for one pick. In a multi-week contest the picked TEAM rides every week
  # of the span, so this sums the team's matchup in each week.
  #
  # Each week keeps its OWN turf_score rather than applying one flat multiplier
  # to summed goals: a team with a soft Week 1 and a brutal Weeks 2-3 must be
  # weighted week by week. That per-week weighting is the whole normalization
  # edge of a multi-week contest.
  #
  # Weeks with no result yet (and bye weeks, which have no matchup at all)
  # contribute nothing, so the leaderboard accrues live as each week completes.
  # With NO week scored yet, points are left untouched — matching the
  # single-week behaviour exactly.
  def compute_points!
    scored = scoring_matchups.select { |matchup| matchup.goals.present? && matchup.turf_score.present? }
    return if scored.empty?

    update!(points: scored.sum { |matchup| matchup.goals * matchup.turf_score })
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
