require "test_helper"
require "tempfile"

class Nfl::CacheExpectedTeamTotalsTest < ActiveSupport::TestCase
  test "derives home and away expected points from total and home spread" do
    totals = Nfl::CacheExpectedTeamTotals.derive(game_total: "47.5", home_spread: "-3.5")

    assert_equal BigDecimal("25.50"), totals.fetch(:home)
    assert_equal BigDecimal("22.00"), totals.fetch(:away)
  end

  test "caches projections and creates missing week slate data" do
    result = Nfl::CacheExpectedTeamTotals.call(path: csv_path)

    assert_equal 1, result.rows
    assert_equal 1, result.games_created
    assert_equal 1, result.slates_created
    assert_equal 2, result.matchups_created
    assert_equal 2, result.projections_upserted

    game = Game.find_by!(slug: "team-a-vs-team-b")
    slate = Slate.find_by!(name: "NFL 2026 Week 18")
    home_projection = NflTeamTotalProjection.find_by!(year: 2026, week: 18, game_slug: game.slug, team_slug: "team-a")
    away_projection = NflTeamTotalProjection.find_by!(year: 2026, week: 18, game_slug: game.slug, team_slug: "team-b")

    assert_equal slate, home_projection.slate
    assert home_projection.home?
    assert_equal BigDecimal("25.00"), home_projection.expected_points
    assert_equal BigDecimal("22.00"), away_projection.expected_points
    assert_equal "Team A Lookahead", home_projection.source_text
    assert_equal 2, slate.slate_matchups.where(game_slug: game.slug).count
  end

  test "re-running cache updates rows without duplicating projections" do
    Nfl::CacheExpectedTeamTotals.call(path: csv_path)
    Nfl::CacheExpectedTeamTotals.call(path: csv_path)

    assert_equal 2, NflTeamTotalProjection.where(year: 2026, week: 18, game_slug: "team-a-vs-team-b").count
    assert_equal 1, Game.where(slug: "team-a-vs-team-b").count
  end

  private

  def csv_path
    file = Tempfile.new(["team_totals", ".csv"])
    file.write <<~CSV
      week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total,source,source_published_on,source_url,source_text
      18,team-b,team-a,team-a,-3,47,test_source,2026-05-26,https://example.test/team-totals,Team A Lookahead
    CSV
    file.close
    file.path
  end
end
