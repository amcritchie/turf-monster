require "test_helper"

# A multi-week Turf Totals contest ("NFL Week 1-3"): the player picks six TEAMS
# once, before Week 1 kickoff, and those same six ride every week of the span.
# Score is the sum of each pick's weekly points, each week weighted by its own
# turf_score.
class MultiWeekContestTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @week1 = slates(:one)
    @week2 = Slate.create!(name: "Test Slate Week 2", slug: "test-slate-week-2")
    @week3 = Slate.create!(name: "Test Slate Week 3", slug: "test-slate-week-3")
  end

  # team-a plays in all three weeks. Expected points (dk_goals_expectation) are
  # what the SPAN multiplier is ranked on — the per-week turf_score values are
  # deliberately varied to prove they no longer drive multi-week scoring.
  def build_span!
    @w2_a = SlateMatchup.create!(slate: @week2, team_slug: "team-a", opponent_team_slug: "team-c",
                                 rank: 1, turf_score: 2.0, dk_goals_expectation: 2.0, status: "pending")
    @w3_a = SlateMatchup.create!(slate: @week3, team_slug: "team-a", opponent_team_slug: "team-d",
                                 rank: 1, turf_score: 3.0, dk_goals_expectation: 2.0, status: "pending")
    @contest.assign_week_slates!([@week1.id, @week2.id, @week3.id])
  end

  def pick_team_a!
    entry = entries(:one)
    entry.selections.destroy_all
    Selection.create!(entry: entry, slate_matchup: slate_matchups(:m1))
  end

  # --- span shape ---------------------------------------------------------

  test "a slate-backed contest is single-week and backfilled to one anchor row" do
    assert_not @contest.multi_week?
    assert_equal 1, @contest.weeks_count
    assert_equal [@week1], @contest.week_slates
  end

  test "assign_week_slates! records the span in order and anchors on week one" do
    build_span!

    assert @contest.multi_week?
    assert_equal 3, @contest.weeks_count
    assert_equal [@week1, @week2, @week3], @contest.week_slates
    assert_equal [1, 2, 3], @contest.contest_slates.map(&:position)
    # slate_id must stay the anchor — picks_required, locking, and every
    # pre-existing query still read through it.
    assert_equal @week1.id, @contest.slate_id
  end

  test "assign_week_slates! is idempotent and does not duplicate join rows" do
    build_span!
    @contest.assign_week_slates!([@week1.id, @week2.id, @week3.id])

    assert_equal 3, @contest.contest_slates.count
  end

  test "picks are made from week one only and the pick count is unchanged" do
    build_span!

    # The pickable universe stays the anchor week: you pick a TEAM, once.
    assert_equal @week1.slate_matchups.sort, @contest.matchups.sort
    assert_equal Contest::TURF_TOTALS_DEFAULT_PICKS_REQUIRED, @contest.picks_required
  end

  test "matchups_for_team spans every week" do
    build_span!

    found = @contest.matchups_for_team("team-a")
    assert_equal 3, found.count
    assert_equal [@week1.id, @week2.id, @week3.id].sort, found.map(&:slate_id).sort
  end

  # --- scoring ------------------------------------------------------------

  test "a pick scores its total span goals times the ONE span multiplier" do
    build_span!
    selection = pick_team_a!

    slate_matchups(:m1).update!(goals: 2)
    @w2_a.update!(goals: 3)
    @w3_a.update!(goals: 1)

    selection.compute_points!

    multiplier = @contest.span_turf_score_for("team-a")
    assert_equal (6 * multiplier).to_f, selection.reload.points.to_f
  end

  test "per-week turf_scores do NOT drive multi-week scoring" do
    build_span!
    selection = pick_team_a!
    slate_matchups(:m1).update!(goals: 2)
    @w2_a.update!(goals: 3)
    @w3_a.update!(goals: 1)
    selection.compute_points!
    before = selection.reload.points.to_f

    # Swing the individual weeks' multipliers wildly. Under the span model the
    # score must not move — only the summed EXPECTED points (which set the span
    # multiplier) and the actual goals matter.
    slate_matchups(:m1).update!(turf_score: 9.9)
    @w2_a.update!(turf_score: 0.1)
    selection.compute_points!

    assert_equal before, selection.reload.points.to_f
  end

  test "the span multiplier ranks on expected points summed across the weeks" do
    build_span!

    # Give team-a the highest three-week expectation and team-b the lowest.
    @contest.matchups_by_team.each do |team_slug, matchups|
      matchups.each { |m| m.update!(dk_goals_expectation: team_slug == "team-a" ? 9.9 : 0.1) }
    end
    slate_matchups(:m2).update!(dk_goals_expectation: 0.0) # team-b lowest

    scores = @contest.span_turf_scores

    # turf_score_for(1, n) is exactly 1.0 and turf_score_for(n, n) is exactly
    # 3.0, whatever n is — so the extremes are assertable without knowing the
    # pool size. Highest expected points = lowest multiplier.
    assert_equal 1.0, scores["team-a"]
    assert_equal 3.0, scores.values.max
    assert_operator scores["team-b"], :>, scores["team-a"]
  end

  test "the span multiplier is one number, not one per week" do
    build_span!

    # The whole point of the span multiplier: a player reads the same single
    # "points per goal" number they'd read on a one-week contest.
    assert_kind_of Numeric, @contest.span_turf_score_for("team-a")
  end

  test "only completed weeks contribute so the leaderboard accrues live" do
    build_span!
    selection = pick_team_a!

    slate_matchups(:m1).update!(goals: 2) # week 1 done, weeks 2-3 unplayed
    selection.compute_points!

    multiplier = @contest.span_turf_score_for("team-a")
    assert_equal (2 * multiplier).to_f, selection.reload.points.to_f
  end

  test "points are left untouched when no week has a result yet" do
    build_span!
    selection = pick_team_a!
    selection.update!(points: 7.5)

    selection.compute_points!

    assert_equal 7.5, selection.reload.points.to_f
  end

  test "a bye week contributes no goals instead of raising" do
    # team-e plays week 1 and week 3, but is on bye in week 2.
    bye_w3 = SlateMatchup.create!(slate: @week3, team_slug: "team-e", opponent_team_slug: "team-f",
                                  rank: 5, turf_score: 2.0, dk_goals_expectation: 2.0, status: "pending")
    @contest.assign_week_slates!([@week1.id, @week2.id, @week3.id])

    entry = entries(:one)
    entry.selections.destroy_all
    selection = Selection.create!(entry: entry, slate_matchup: slate_matchups(:m5))

    slate_matchups(:m5).update!(goals: 1)
    bye_w3.update!(goals: 2)

    assert_nothing_raised { selection.compute_points! }
    multiplier = @contest.span_turf_score_for("team-e")
    assert_equal (3 * multiplier).to_f, selection.reload.points.to_f
  end

  test "entry score sums its picks across the whole span" do
    build_span!
    entry = entries(:one)
    entry.selections.destroy_all
    Selection.create!(entry: entry, slate_matchup: slate_matchups(:m1)) # team-a, all 3 weeks
    Selection.create!(entry: entry, slate_matchup: slate_matchups(:m2)) # team-b, week 1 only

    slate_matchups(:m1).update!(goals: 2)
    @w2_a.update!(goals: 3)
    @w3_a.update!(goals: 1)
    slate_matchups(:m2).update!(goals: 5)

    # reload: the selections were created behind this instance's cached
    # association. Production always scores a freshly-loaded entry
    # (Contest#score_entries! -> entries.find_each).
    entry.reload.score!

    expected = (6 * @contest.span_turf_score_for("team-a")) +
               (5 * @contest.span_turf_score_for("team-b"))
    assert_in_delta expected.to_f, entry.reload.score, 0.001
  end

  test "weekly_breakdown returns one entry per week in order, nil on a bye" do
    build_span!
    selection = pick_team_a!

    breakdown = selection.weekly_breakdown
    assert_equal [@week1, @week2, @week3], breakdown.map(&:first)
    assert_equal [slate_matchups(:m1), @w2_a, @w3_a], breakdown.map(&:last)
  end

  # --- the scoring trigger ------------------------------------------------

  test "a later-week game re-scores the contest even though it is not the anchor" do
    build_span!
    selection = pick_team_a!

    game = Game.create!(slug: "wk2-a-vs-c", home_team_slug: "team-a", away_team_slug: "team-c",
                        kickoff_at: 1.day.ago, status: "completed")
    @w2_a.update!(game_slug: game.slug)

    # A Week 2 slate is never the contest's anchor slate_id — an anchor-only
    # lookup would silently never re-score it.
    affected = Contest.where(slate_id: [@week2.id]).ids
    assert_empty affected, "week 2 must not be reachable via the anchor"

    game.update!(home_score: 3, away_score: 0)
    game.update_slate_matchups!

    multiplier = @contest.span_turf_score_for("team-a")
    assert_equal (3 * multiplier).to_f, selection.reload.points.to_f
  end

  # --- single-week regression --------------------------------------------

  test "single-week scoring is unchanged" do
    selection = pick_team_a!
    slate_matchups(:m1).update!(goals: 4) # turf_score 1.0

    selection.compute_points!

    assert_equal 4.0, selection.reload.points.to_f
  end

  test "single-week points are left untouched when the week has no result" do
    selection = pick_team_a!
    selection.update!(points: 3.3)
    slate_matchups(:m1).update!(goals: nil)

    selection.compute_points!

    assert_equal 3.3, selection.reload.points.to_f
  end
end
