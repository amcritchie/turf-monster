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
                               rank: 1, turf_score: 2.0, status: "pending")
    @w3 = SlateMatchup.create!(slate: @week3, team_slug: "team-a", opponent_team_slug: "team-d",
                               rank: 1, turf_score: 3.0, status: "pending")
    @contest.assign_week_slates!([@week1.id, @week2.id, @week3.id])

    entry = entries(:one)
    entry.selections.destroy_all
    @selection = Selection.create!(entry: entry, slate_matchup: slate_matchups(:m1))
  end

  def breakdown
    weekly_points_breakdown(@selection.reload,
                            weeks: @contest.week_slates,
                            by_team: @contest.matchups_by_team)
  end

  test "shows every week and the cumulative total" do
    slate_matchups(:m1).update!(goals: 2) # x1.0 -> 2.0
    @w2.update!(goals: 3)                 # x2.0 -> 6.0
    @w3.update!(goals: 1)                 # x3.0 -> 3.0
    @selection.compute_points!

    assert_equal "W1 2.0 · W2 6.0 · W3 3.0 = 11.0 pts", breakdown
  end

  test "an unplayed week shows a dash, not a zero" do
    slate_matchups(:m1).update!(goals: 2)
    @selection.compute_points!

    # A dash distinguishes "hasn't happened yet" from "was shut out" — a zero
    # for weeks 2 and 3 would read as the team having been held scoreless.
    assert_equal "W1 2.0 · W2 — · W3 — = 2.0 pts", breakdown
  end

  test "a shutout week shows 0.0, distinct from an unplayed one" do
    slate_matchups(:m1).update!(goals: 2)
    @w2.update!(goals: 0)
    @selection.compute_points!

    assert_equal "W1 2.0 · W2 0.0 · W3 — = 2.0 pts", breakdown
  end

  test "a bye week shows a dash rather than raising" do
    @w3.destroy! # team-a is on bye in week 3
    slate_matchups(:m1).update!(goals: 2)
    @w2.update!(goals: 3)
    @selection.compute_points!

    assert_equal "W1 2.0 · W2 6.0 · W3 — = 8.0 pts", breakdown
  end
end
