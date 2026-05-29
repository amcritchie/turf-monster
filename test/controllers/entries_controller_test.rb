require "test_helper"

class EntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    @owner   = users(:sam)
    @other   = users(:jordan)
    @m1 = slate_matchups(:m1)
    @m2 = slate_matchups(:m2)
    @m3 = slate_matchups(:m3)
    @m4 = slate_matchups(:m4)
    @m5 = slate_matchups(:m5)
    @m6 = slate_matchups(:m6)
    @entry = @contest.entries.create!(user: @owner, status: :active)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| @entry.selections.create!(slate_matchup: m) }
    @entry.reload  # picks up slug populated by after_create
  end

  test "update replaces selections for the entry owner" do
    log_in_as(@owner)
    # Need a 7th matchup with a fresh team — team_slug is unique per slate
    # and Sluggable derives slug from name.
    team = Team.find_by(slug: "team-g") || Team.create!(name: "Team G", short_name: "G", emoji: "\u{1F3F3}")
    m7 = SlateMatchup.create!(slate: @contest.slate, team_slug: team.slug, opponent_team_slug: "team-a",
                                rank: 7, turf_score: 1.8, status: "pending")

    patch contest_entry_path(@contest, @entry),
          params: { matchup_ids: [@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, m7.id] },
          as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert_equal [@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, m7.id].sort,
                 @entry.reload.selections.map(&:slate_matchup_id).sort
  end

  test "update returns 404 when entry does not belong to current user" do
    log_in_as(@other)

    patch contest_entry_path(@contest, @entry),
          params: { matchup_ids: [@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, @m6.id] },
          as: :json

    assert_response :not_found
  end

  test "update returns 404 when entry is on a different contest" do
    log_in_as(@owner)
    other_contest = Contest.create!(name: "Other", slate: @contest.slate, contest_type: "standard",
                                       entry_fee_cents: 0, max_entries: 29, status: :open,
                                       starts_at: 2.weeks.from_now)

    patch contest_entry_path(other_contest, @entry),
          params: { matchup_ids: [@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, @m6.id] },
          as: :json

    assert_response :not_found
  end

  test "update rejects cart entries (only active are editable)" do
    log_in_as(@owner)
    @entry.update!(status: :cart)

    patch contest_entry_path(@contest, @entry),
          params: { matchup_ids: [@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, @m6.id] },
          as: :json

    assert_response :unprocessable_entity
    assert_match(/only active/i, JSON.parse(response.body)["error"])
  end

  test "update rejects when contest is locked" do
    log_in_as(@owner)
    # v0.17: locking is derived — a past lock time, not a status, closes edits.
    @contest.update!(starts_at: 1.hour.ago)

    patch contest_entry_path(@contest, @entry),
          params: { matchup_ids: [@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, @m6.id] },
          as: :json

    assert_response :unprocessable_entity
    assert_match(/locked/i, JSON.parse(response.body)["error"])
  end

  test "update rejects fewer than picks_required matchups" do
    log_in_as(@owner)

    patch contest_entry_path(@contest, @entry),
          params: { matchup_ids: [@m1.id, @m2.id, @m3.id] },
          as: :json

    assert_response :unprocessable_entity
    assert_match(/selections required/i, JSON.parse(response.body)["error"])
  end

  test "update requires authentication" do
    patch contest_entry_path(@contest, @entry),
          params: { matchup_ids: [@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, @m6.id] },
          as: :json

    assert_response :unauthorized
  end
end
