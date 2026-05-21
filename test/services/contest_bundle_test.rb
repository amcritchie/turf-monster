require "test_helper"

class ContestBundleTest < ActiveSupport::TestCase
  # Uses the "survivor" bundle — it needs no slate, so it provisions cleanly
  # against test fixtures. (On-chain creation auto-skips in the test env.)

  test "generate! creates the contest and its landing page" do
    assert_difference ["Contest.count", "LandingPage.count"], 1 do
      ContestBundle.generate!("survivor", creator: users(:alex))
    end
    lp = LandingPage.find_by(slug: "survivor")
    assert lp.active?
    assert_equal "gradient", lp.background_style
    assert_equal "World Cup Survivor Free Roll", lp.contest.name
  end

  test "generate! is idempotent" do
    ContestBundle.generate!("survivor", creator: users(:alex))
    assert_no_difference ["Contest.count", "LandingPage.count"] do
      ContestBundle.generate!("survivor", creator: users(:alex))
    end
  end

  test "generate! raises on an unknown bundle key" do
    assert_raises(ArgumentError) { ContestBundle.generate!("nope") }
  end
end
