require "test_helper"

# /slates/formula_report overlays the NFL points-distribution model as its own
# section: rank chart data, both fitted formulas, and the 32-row rank table.
class SlatesFormulaReportNflTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex)) # admin — the formula report is admin-gated
  end

  test "renders the NFL section from the checked-in dataset" do
    get formula_report_slates_path

    assert_response :success
    assert_select "h2", text: "NFL Points Distribution"
    assert_select "canvas#chart-nfl-dist", 1
    assert_includes response.body, "_nflDist"
    assert_includes response.body, "Linear — best fit"
    assert_includes response.body, "Log — World Cup family"

    # Rank table: header row + one row per team.
    result = Nfl::PointsDistribution.call
    assert_select "table" do
      assert_select "td", text: format("%.2f", result.expected_points_by_rank.first)
    end
    assert_equal 32, result.team_count
  end

  test "hides the NFL section when the dataset is missing" do
    raises_missing = ->(*) { raise ArgumentError, "Missing historical scores dataset" }

    Nfl::PointsDistribution.stub(:call, raises_missing) do
      get formula_report_slates_path
    end

    assert_response :success
    assert_select "canvas#chart-nfl-dist", 0
    refute_includes response.body, "_nflDist"
  end
end
