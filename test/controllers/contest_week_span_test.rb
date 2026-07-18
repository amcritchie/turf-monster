require "test_helper"

# The create form's "Weeks" control and the server-side span resolution behind
# it. The span is deliberately NOT trusted from the form as a list of slate ids —
# the controller resolves consecutive weeks from the anchor.
class ContestWeekSpanTest < ActionDispatch::IntegrationTest
  setup do
    @w1 = Slate.create!(name: "NFL 2026 Week 1", slug: "nfl-2026-week-1", week: 1)
    @w2 = Slate.create!(name: "NFL 2026 Week 2", slug: "nfl-2026-week-2", week: 2)
    @w3 = Slate.create!(name: "NFL 2026 Week 3", slug: "nfl-2026-week-3", week: 3)
    log_in_as(users(:alex)) # admin
  end

  test "the create form offers a week span control" do
    get new_contest_path

    assert_response :success
    assert_select "select#contest_week_span"
    assert_select "select#contest_week_span option", text: "3 weeks"
  end

  test "weekly NFL slates are selectable even though they have no start time" do
    # These slates carry a week but no starts_at (the projections feed has no
    # kickoff times); the old options query filtered them out entirely.
    assert_nil @w1.starts_at

    get new_contest_path

    assert_response :success
    assert_select "select#contest_slate_id option", text: "NFL 2026 Week 1"
  end

  test "a contest built with a span records consecutive weeks in order" do
    contest = Contest.new(
      name: "Week 1-3 Test", slug: "week-1-3-test", contest_type: "standard",
      status: :open, slate_id: @w1.id, starts_at: 10.days.from_now,
      entry_fee_cents: 1900, max_entries: 29
    )
    contest.pending_week_slate_ids = @w1.consecutive_weeks(3).map(&:id)
    contest.save!

    assert_equal [@w1, @w2, @w3], contest.week_slates
    assert_equal "Weeks 1-3", contest.week_span_label
    assert contest.multi_week?
  end

  test "the anchor always takes position one even if the span is mis-ordered" do
    contest = Contest.new(
      name: "Mis-ordered Span", slug: "mis-ordered-span", contest_type: "standard",
      status: :open, slate_id: @w1.id, starts_at: 10.days.from_now,
      entry_fee_cents: 1900, max_entries: 29
    )
    contest.pending_week_slate_ids = [@w3.id, @w2.id, @w1.id]
    contest.save!

    # slate_id is the anchor and defines the pickable set + the lock; position 1
    # must never drift away from it.
    assert_equal @w1, contest.week_slates.first
    assert_equal @w1.id, contest.contest_slates.find_by(position: 1).slate_id
  end

  test "the contest page names the span and shows each week's points" do
    contest = contests(:one)
    @week1 = slates(:one)
    @week1.update!(week: 1)
    w2_a = SlateMatchup.create!(slate: @w2, team_slug: "team-a", opponent_team_slug: "team-c",
                                rank: 1, turf_score: 2.0, status: "pending")
    contest.assign_week_slates!([@week1.id, @w2.id, @w3.id])

    entry = entries(:one)
    entry.selections.destroy_all
    selection = Selection.create!(entry: entry, slate_matchup: slate_matchups(:m1))
    slate_matchups(:m1).update!(goals: 2) # x1.0 -> 2.0
    w2_a.update!(goals: 3)                # x2.0 -> 6.0
    selection.compute_points!

    get contest_path(contest)

    assert_response :success
    # The header must name the SPAN, not just the anchor slate — "Test Slate"
    # alone would read as a single-week contest.
    assert_select "span", text: "Weeks 1-3"
    # Week 3 is unplayed, so it shows a dash rather than a zero.
    assert_includes response.body, "W1 2.0 · W2 6.0 · W3 — = 8.0 pts"
  end

  test "a contest built with no span is single week and unchanged" do
    contest = Contest.new(
      name: "Single Week", slug: "single-week-test", contest_type: "standard",
      status: :open, slate_id: @w1.id, starts_at: 10.days.from_now,
      entry_fee_cents: 1900, max_entries: 29
    )
    contest.save!

    assert_not contest.multi_week?
    assert_equal [@w1], contest.week_slates
    assert_equal 1, contest.contest_slates.count
  end
end
