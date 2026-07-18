require "test_helper"

# The create form's "Weeks" control and the server-side span resolution behind
# it. The span is NOT trusted from the form: the controller resolves it into the
# ONE span slate the contest is played on, and refuses rather than truncates.
class ContestWeekSpanTest < ActionDispatch::IntegrationTest
  setup do
    @w1 = Slate.create!(name: "NFL 2026 Week 1", slug: "nfl-2026-week-1", week: 1)
    @w2 = Slate.create!(name: "NFL 2026 Week 2", slug: "nfl-2026-week-2", week: 2)
    @w3 = Slate.create!(name: "NFL 2026 Week 3", slug: "nfl-2026-week-3", week: 3)
    [[@w1, 1], [@w2, 2], [@w3, 3]].each do |slate, week|
      %w[team-a team-b].each_with_index do |team, index|
        SlateMatchup.create!(slate: slate, team_slug: team, opponent_team_slug: "team-f",
                             game_slug: "#{team}-wk#{week}-#{SecureRandom.hex(3)}",
                             week: week, dk_goals_expectation: 25.0 - index, status: "pending")
      end
    end
    log_in_as(users(:alex)) # admin
  end

  test "the create form offers a week span control" do
    get new_contest_path

    assert_response :success
    assert_select "select#contest_week_span"
    assert_select "select#contest_week_span option", text: "3 weeks"
  end

  test "weekly NFL slates are selectable even though they have no start time" do
    assert_nil @w1.starts_at

    get new_contest_path

    assert_response :success
    assert_select "select#contest_slate_id option", text: "NFL 2026 Week 1"
  end

  test "the generator renders slates that have no start time" do
    # Regression: making weekly slates selectable exposed them to the generator,
    # which called strftime on a nil starts_at and 500'd the whole page.
    assert_nil @w1.starts_at
    assert_nil @w1.first_game_starts_at

    get generator_contests_path

    assert_response :success
    assert_includes response.body, "NFL 2026 Week 1"
    assert_includes response.body, "no scheduled start"
  end

  test "the generator still shows a start time when the slate has one" do
    dated = Slate.create!(name: "Dated Slate", slug: "dated-slate", starts_at: 5.days.from_now)

    get generator_contests_path

    assert_response :success
    assert_includes response.body, "starts #{dated.starts_at.strftime('%b %-d, %Y')}"
  end

  # --- span assembly ------------------------------------------------------

  test "a span builds ONE slate holding every week's games" do
    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    assert_equal "NFL 2026 Weeks 1-3", span.name
    assert_equal 6, span.slate_matchups.count, "2 teams x 3 weeks"
    assert_equal 3, span.games_per_team
    assert span.multi_game_per_team?
  end

  test "the span slate stores a FROZEN multiplier on every row of a team" do
    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    scores = span.matchups_by_team["team-a"].map(&:turf_score).uniq
    assert_equal 1, scores.size, "one multiplier per team, written to all its rows"
    assert scores.first.present?
    # Highest summed expectation ranks 1, which is exactly the 1.0x floor.
    assert_equal 1.0, scores.first.to_f
  end

  test "a span REFUSES a gap instead of silently truncating" do
    @w2.slate_matchups.destroy_all
    @w2.destroy!

    # Truncating here would sell a three-week contest, mint it on-chain with
    # three-week fees and prize pool, and then score it as two weeks.
    error = assert_raises(Nfl::BuildSpanSlate::Error) do
      Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])
    end
    assert_match(/week 2/, error.message)
  end

  test "a span REFUSES a week the season does not have" do
    error = assert_raises(Nfl::BuildSpanSlate::Error) do
      Nfl::BuildSpanSlate.call(year: 2026, weeks: [17, 18, 19])
    end
    assert_match(/17/, error.message)
  end

  test "a span never absorbs a slate from another season" do
    # Same week numbers, different year. slates carry a week but no year column,
    # so the year lives in the name — a lookup on week alone would collapse them.
    other = Slate.create!(name: "NFL 2025 Week 1", slug: "nfl-2025-week-1", week: 1)
    SlateMatchup.create!(slate: other, team_slug: "team-c", opponent_team_slug: "team-f",
                         game_slug: "stale-#{SecureRandom.hex(3)}", week: 1,
                         dk_goals_expectation: 99.0, status: "pending")

    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    assert_not_includes span.matchups_by_team.keys, "team-c",
                        "a 2026 span must not pull in a 2025 slate"
  end

  test "rebuilding a span does not duplicate its games" do
    Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])
    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    assert_equal 6, span.slate_matchups.count
  end

  test "a contest on a span slate is multi-week and labels its span" do
    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])
    contest = contests(:one)
    contest.update!(slate: span)

    assert contest.multi_week?
    assert_equal "Weeks 1-3", contest.week_span_label
    assert_equal 2, contest.pickable_matchups.size, "one pickable row per team"
  end

  test "a single-week contest is unchanged" do
    contest = contests(:one)
    contest.update!(slate: @w1)

    assert_not contest.multi_week?
    assert_equal "Week 1", contest.week_span_label
  end
end
