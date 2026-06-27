require "test_helper"

class ContestKnockoutSlatesTest < ActionDispatch::IntegrationTest
  setup do
    SeasonConfig.set_current!(1)
    seed_real_knockout_teams!
    @teams_by_code = Team.where(short_name: WorldCup2026KnockoutSeed.required_real_team_codes).index_by(&:short_name)
    WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})
    log_in_as(users(:alex))
  end

  test "contest generator renders seeded knockout slates" do
    get generator_contests_path

    assert_response :success
    assert_includes response.body, "World Cup 2026 Round of 32"
    assert_includes response.body, "World Cup 2026 Final"
    assert_includes response.body, "32 matchups available"
  end

  test "new contest defaults to selected knockout slate kickoff" do
    slate = Slate.find_by!(name: "World Cup 2026 Round of 32")

    Solana::Vault.stub :new, FakeVault.new(seasons: [{ season_id: 1, name: "World Cup 2026" }]) do
      get new_contest_path(slate_id: slate.id, contest_type: "medium")
    end

    assert_response :success
    assert_includes response.body, "World Cup 2026 Round of 32"
    assert_includes response.body, "2026-06-28T19:00:00Z"
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
