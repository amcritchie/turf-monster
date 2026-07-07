require "test_helper"

class NflTeamTotalsNavigationTest < ActionDispatch::IntegrationTest
  test "navbar links to the NFL totals page" do
    get games_path

    assert_response :success
    assert_select "header a[href=?]", nfl_team_totals_path, text: "NFL Totals"
  end
end
