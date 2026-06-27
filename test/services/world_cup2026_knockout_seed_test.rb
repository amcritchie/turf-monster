require "test_helper"

class WorldCup2026KnockoutSeedTest < ActiveSupport::TestCase
  setup do
    seed_real_knockout_teams!
    @teams_by_code = Team.where(short_name: WorldCup2026KnockoutSeed.required_real_team_codes).index_by(&:short_name)
  end

  test "seeds all knockout slates games matchups and placeholders" do
    assert_difference -> { Slate.count }, 6 do
      assert_difference -> { Game.count }, 32 do
        assert_difference -> { SlateMatchup.count }, 64 do
          WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})
        end
      end
    end

    round_of_32 = Slate.find_by!(name: "World Cup 2026 Round of 32")
    final = Slate.find_by!(name: "World Cup 2026 Final")

    assert_equal 32, round_of_32.slate_matchups.count
    assert_equal 2, final.slate_matchups.count
    assert_equal Time.iso8601("2026-06-28T19:00:00Z"), round_of_32.first_game_starts_at
    assert_equal Time.iso8601("2026-07-19T19:00:00Z"), final.first_game_starts_at

    assert Team.exists?(short_name: "3CEFHI", name: "Best 3rd C/E/F/H/I")
    assert Team.exists?(short_name: "W101", name: "Winner Match 101")
    assert_equal "Knockout Slot", Team.find_by!(short_name: "RU101").division
  end

  test "seeding is idempotent" do
    WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})

    assert_no_difference -> { Team.count } do
      assert_no_difference -> { Slate.count } do
        assert_no_difference -> { Game.count } do
          assert_no_difference -> { SlateMatchup.count } do
            WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})
          end
        end
      end
    end
  end

  private

  def seed_real_knockout_teams!
    WorldCup2026KnockoutSeed.required_real_team_codes.each do |code|
      Team.find_or_create_by!(short_name: code) do |team|
        team.name = "Team #{code}"
        team.location = "Team #{code}"
        team.emoji = "🏳️"
        team.color_primary = "#111827"
        team.color_secondary = "#F9FAFB"
        team.sport = "soccer"
        team.league = "fifa"
        team.division = "Test"
        team.rivals = []
      end
    end
  end
end
