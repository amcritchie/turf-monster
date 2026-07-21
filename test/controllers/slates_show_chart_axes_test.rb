require "test_helper"

# The Turf Score Formula chart's axis contract: DK Expectation plots against
# its own auto-scaling axis with labels on the LEFT, so an NFL span total
# (~81) reads accurately; Turf Score keeps its 0-5 scale on the right. The
# old config bound DK to the 0-5 turf axis (drawing real totals off-chart)
# beside a decorative right-hand "DK Total" axis hardcoded to 0-5.
class SlatesShowChartAxesTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex)) # admin — the ranking UI is admin-gated
    @slate = Slate.create!(name: "NFL 2026 Weeks 1-3 Test", slug: "nfl-2026-weeks-1-3-test")
  end

  test "DK expectation binds to a left auto-scaling axis" do
    get slate_path(@slate)

    assert_response :success
    # The DK dataset is the only spanGaps series — its binding rides with it.
    assert_includes response.body, "yAxisID: 'y2', spanGaps: true"
    assert_includes response.body, "y2: { position: 'left'"
    assert_includes response.body, "y: { position: 'right'"
    assert_includes response.body, "beginAtZero: true"
    refute_includes response.body, "y2: { position: 'right'"
    # Only the Turf Score axis stays pinned to 0-5.
    assert_equal 1, response.body.scan("max: 5").count
  end
end
