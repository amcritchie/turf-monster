require "test_helper"

class Nfl::FetchHistoricalScoresTest < ActiveSupport::TestCase
  test "parses completed regular-season games for the requested season" do
    rows = Nfl::FetchHistoricalScores.rows_from(espn_payload, season: 2024)

    assert_equal 1, rows.length
    assert_equal(
      {
        "season" => 2024,
        "week" => 1,
        "away" => "BAL",
        "away_score" => 20,
        "home" => "KC",
        "home_score" => 27
      },
      rows.first
    )
  end

  test "drops postseason, other seasons, and unfinished games" do
    rows = Nfl::FetchHistoricalScores.rows_from(espn_payload, season: 2023)

    assert_equal [], rows
  end

  private

  # Trimmed to the fields the parser reads, in ESPN scoreboard shape: one
  # keeper, one postseason game, one still in progress.
  def espn_payload
    {
      "events" => [
        espn_event(year: 2024, type: 2, week: 1, away: ["BAL", "20"], home: ["KC", "27"], completed: true),
        espn_event(year: 2024, type: 3, week: 1, away: ["HOU", "14"], home: ["KC", "23"], completed: true),
        espn_event(year: 2024, type: 2, week: 2, away: ["CIN", "3"], home: ["KC", "7"], completed: false)
      ]
    }
  end

  def espn_event(year:, type:, week:, away:, home:, completed:)
    {
      "season" => { "year" => year, "type" => type },
      "week" => { "number" => week },
      "competitions" => [
        {
          "status" => { "type" => { "completed" => completed } },
          "competitors" => [
            { "homeAway" => "home", "score" => home[1], "team" => { "abbreviation" => home[0] } },
            { "homeAway" => "away", "score" => away[1], "team" => { "abbreviation" => away[0] } }
          ]
        }
      ]
    }
  end
end
