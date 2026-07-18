require "test_helper"

# The per-week breakdown a multi-week pick shows on the leaderboard.
class MultiWeekBreakdownTest < ActionView::TestCase
  include ContestsHelper

  setup do
    @contest = contests(:one)
    @week1 = slates(:one)
    @week1.update!(week: 1)
    @week2 = Slate.create!(name: "NFL 2026 Week 2", slug: "nfl-2026-week-2", week: 2)
    @week3 = Slate.create!(name: "NFL 2026 Week 3", slug: "nfl-2026-week-3", week: 3)

    @w2 = SlateMatchup.create!(slate: @week2, team_slug: "team-a", opponent_team_slug: "team-c",
                               rank: 1, turf_score: 2.0, dk_goals_expectation: 2.0, status: "pending")
    @w3 = SlateMatchup.create!(slate: @week3, team_slug: "team-a", opponent_team_slug: "team-d",
                               rank: 1, turf_score: 3.0, dk_goals_expectation: 2.0, status: "pending")
    @contest.assign_week_slates!([@week1.id, @week2.id, @week3.id])

    entry = entries(:one)
    entry.selections.destroy_all
    @selection = Selection.create!(entry: entry, slate_matchup: slate_matchups(:m1))
  end

  def breakdown(multiplier: 2.0)
    weekly_points_breakdown(@selection.reload,
                            weeks: @contest.week_slates,
                            by_team: @contest.matchups_by_team,
                            multiplier: multiplier)
  end

  test "shows each week's goals, the span total, and the one multiplier" do
    slate_matchups(:m1).update!(goals: 2)
    @w2.update!(goals: 3)
    @w3.update!(goals: 1)
    @selection.compute_points!

    assert_equal "W1 2 · W2 3 · W3 1 · 6 goals × 2.0 = #{format('%.1f', @selection.reload.points)} pts",
                 breakdown
  end

  test "an unplayed week shows a dash, not a zero" do
    slate_matchups(:m1).update!(goals: 2)
    @selection.compute_points!

    # A dash distinguishes "hasn't happened yet" from "was shut out" — a zero
    # for weeks 2 and 3 would read as the team having been held scoreless.
    assert_includes breakdown, "W1 2 · W2 — · W3 —"
    assert_includes breakdown, "2 goals"
  end

  test "a shutout week shows 0, distinct from an unplayed one" do
    slate_matchups(:m1).update!(goals: 2)
    @w2.update!(goals: 0)
    @selection.compute_points!

    assert_includes breakdown, "W1 2 · W2 0 · W3 —"
    assert_includes breakdown, "2 goals"
  end

  test "a bye week shows a dash rather than raising" do
    @w3.destroy! # team-a is on bye in week 3
    slate_matchups(:m1).update!(goals: 2)
    @w2.update!(goals: 3)
    @selection.compute_points!

    assert_includes breakdown, "W1 2 · W2 3 · W3 —"
    assert_includes breakdown, "5 goals"
  end
end
