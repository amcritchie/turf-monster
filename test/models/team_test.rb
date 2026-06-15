require "test_helper"

class TeamTest < ActiveSupport::TestCase
  test "belongs to home arena by slug" do
    team = teams(:team_a)

    assert_equal arenas(:test_stadium), team.home_arena
  end

  test "league scopes return teams by metadata" do
    assert_includes Team.nfl, teams(:team_a)
    assert_includes Team.football, teams(:team_a)
  end

  test "mascot removes location prefix" do
    team = Team.new(name: "Seattle Seahawks", location: "Seattle")

    assert_equal "Seahawks", team.mascot
  end
end
