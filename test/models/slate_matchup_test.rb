require "test_helper"

class SlateMatchupTest < ActiveSupport::TestCase
  test "name_slug is scoped by slate" do
    matchup = slate_matchups(:m1)

    assert_equal "test-slate-team-a-vs-team-b", matchup.name_slug
  end
end
