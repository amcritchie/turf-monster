require "test_helper"

class NflTeamTotalProjectionTest < ActiveSupport::TestCase
  setup do
    @projection = NflTeamTotalProjection.new(
      year: 2026,
      week: 1,
      game: games(:future_game),
      team: teams(:team_c),
      opponent_team: teams(:team_d),
      home: true,
      expected_points: 24.5,
      game_total: 47.5,
      home_spread: -1.5,
      favorite_team: teams(:team_c),
      favorite_spread: -1.5,
      source: "test_source",
      cached_at: Time.current
    )
  end

  test "is valid with sportsbook projection attributes" do
    assert @projection.valid?
  end

  test "requires a regular season week" do
    @projection.week = 19

    assert_not @projection.valid?
    assert_includes @projection.errors[:week], "must be in 1..18"
  end

  test "formats pickem spreads" do
    @projection.favorite_spread = 0

    assert_equal "PK", @projection.spread_label
  end
end
