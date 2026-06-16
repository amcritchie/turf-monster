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

  test "stores mascot when it can be derived" do
    team = Team.create!(name: "Denver Broncos", location: "Denver")

    assert_equal "Broncos", team.reload[:mascot]
    assert_equal "Broncos", team.mascot
  end

  test "stores logo metadata explicitly" do
    team = Team.create!(
      name: "Denver Broncos",
      location: "Denver",
      logo_url: "https://example.com/broncos.png",
      logo_path: "/team-logos/denver-broncos.png",
      logo_source: "manual"
    )

    team.reload
    assert_equal "https://example.com/broncos.png", team.logo_url
    assert_equal "/team-logos/denver-broncos.png", team.logo_path
    assert_equal "manual", team.logo_source
  end
end
