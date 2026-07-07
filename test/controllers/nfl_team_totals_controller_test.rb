require "test_helper"
require "tempfile"

class NflTeamTotalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    cache_projection_rows!
  end

  test "renders the public NFL team totals dashboard" do
    get nfl_team_totals_path

    assert_response :success
    assert_select "h1", "NFL Team Totals"
    assert_select "a[href=?]", nfl_team_totals_path
    assert_select "article[data-total-card]", 1
    assert_select "nav[aria-label='NFL weeks'] a", text: "Week 1"
    assert_select "nav[aria-label='NFL weeks'] a", text: "Week 18"
    assert_match "Team C at Team A", response.body
  end

  test "switches selected week from query params" do
    get nfl_team_totals_path(week: 18)

    assert_response :success
    assert_select "a[aria-current='page']", "Week 18"
    assert_match "Team B at Team A", response.body
    assert_no_match "Team C at Team A", response.body
  end

  private

  def cache_projection_rows!
    file = Tempfile.new(["team_totals", ".csv"])
    file.write <<~CSV
      week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total,source,source_published_on,source_url,source_text
      1,team-c,team-a,team-c,-2.5,44.5,test_source,2026-05-26,https://example.test/week1,Team C Lookahead
      18,team-b,team-a,team-a,-3,47,test_source,2026-05-26,https://example.test/week18,Team A Lookahead
    CSV
    file.close
    Nfl::CacheExpectedTeamTotals.call(path: file.path)
  end
end
