require "test_helper"
require "nokogiri"

class ContestsLeaderboardPayoutTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
  end

  test "leaderboard renders projected payout ladder and row badges" do
    fragment = leaderboard_fragment

    assert fragment.at_css("[data-payout-ladder][data-payout-state='projected']")
    assert_equal "Projected", fragment.at_css("[data-payout-state]").text.squish
    assert_includes fragment.at_css("[data-payout-rank='1']").text, "1st"
    assert_includes fragment.at_css("[data-payout-rank='1']").text, "$300.00"
    assert fragment.at_css("[data-entry-payout-badge][data-payout-state='projected']")
    assert_includes fragment.text, "Ties split the prize slots they span"
  end

  test "settled leaderboard renders final payout treatment" do
    entries = @contest.entries.order(:id).to_a
    entries[0].update!(status: "complete", rank: 1, payout_cents: 17_500, score: 10.0)
    entries[1].update!(status: "complete", rank: 1, payout_cents: 17_500, score: 10.0)
    @contest.update!(status: "settled")

    fragment = leaderboard_fragment

    assert fragment.at_css("[data-payout-ladder][data-payout-state='settled']")
    assert_equal "Settled", fragment.at_css("[data-payout-state]").text.squish
    badge = fragment.at_css("[data-entry-payout-badge][data-payout-state='settled']")
    assert_includes badge.text, "Won"
    assert_includes badge.text, "$175.00"
    assert_includes fragment.text, "row winnings show the final share"
  end

  private

  def leaderboard_fragment
    get contest_leaderboard_poll_path(@contest, version: 0)

    assert_response :success
    payload = JSON.parse(response.body)
    assert payload["changed"], "leaderboard poll should render updated HTML"
    Nokogiri::HTML.fragment(payload.fetch("html"))
  end
end
