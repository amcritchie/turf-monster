require "test_helper"

class ArenaTest < ActiveSupport::TestCase
  test "generates slug from name" do
    arena = Arena.create!(name: "Lumen Field")

    assert_equal "lumen-field", arena.slug
  end

  test "has home teams by home arena slug" do
    arena = arenas(:test_stadium)

    assert_includes arena.home_teams, teams(:team_a)
  end
end
