require "test_helper"

# Component tier for the redesigned multi-week team card: renders the real
# partial and asserts the new identity block (city over mascot, team gradient,
# accent mascot, light-forward flip) without depending on contest fixtures.
class MultiWeekTeamCardTest < ActionView::TestCase
  include ApplicationHelper
  include TeamColorsHelper

  MatchupDouble = Struct.new(:id, :team, :locked, keyword_init: true) do
    def locked? = locked
  end
  WeekMatchupDouble = Struct.new(:opponent_team, keyword_init: true)

  # Real (unsaved) Team so the card's palette helpers read the actual color API:
  # a dark-disposition Ravens by default (navy field, gold mascot).
  def team_double(**overrides)
    Team.new({
      name: "Baltimore Ravens", location: "Baltimore",
      emoji: "🐦‍⬛", short_name: "BAL",
      color_dark: "#241773", color_light: "#9e7c0c", color_disposition: "dark"
    }.merge(overrides))
  end

  def opponents_double
    [
      [1, WeekMatchupDouble.new(opponent_team: team_double(name: "Indianapolis Colts", emoji: "🐴", short_name: "IND"))],
      [2, nil], # bye
      [3, WeekMatchupDouble.new(opponent_team: team_double(name: "Dallas Cowboys", emoji: "⭐", short_name: "DAL"))]
    ]
  end

  def render_card(team, multiplier: 1.1)
    render(partial: "contests/multi_week_team_card",
           locals: { matchup: MatchupDouble.new(id: 42, team: team, locked: false),
                     multiplier: multiplier, opponents: opponents_double })
  end

  test "card splits city and mascot onto separate lines" do
    html = render_card(team_double)
    assert_includes html, "Baltimore"
    assert_includes html, "Ravens"
  end

  test "card drops the big team mascot emoji" do
    html = render_card(team_double)
    refute_includes html, "🐦‍⬛", "the header mascot emoji should be gone"
  end

  test "card paints a team-color gradient background" do
    html = render_card(team_double)
    assert_includes html, "linear-gradient"
  end

  test "mascot uses the accent color (a well-contrasting secondary)" do
    html = render_card(team_double)
    assert_match(/Ravens/, html)
    assert_includes html, "#9e7c0c", "mascot should render in the accent color"
  end

  test "dark team uses light foreground text" do
    html = render_card(team_double)
    assert_includes html, TeamColorsHelper::LIGHT_FG
  end

  test "light-forward team flips to dark foreground and a dark accent" do
    saints = team_double(name: "New Orleans Saints", location: "New Orleans",
                         emoji: "⚜️", short_name: "NO",
                         color_dark: "#101820", color_light: "#d3bc8d", color_disposition: "light")
    html = render_card(saints)
    assert_includes html, "New Orleans"
    assert_includes html, "Saints"
    assert_includes html, TeamColorsHelper::DARK_FG
    assert_includes html, "#101820"
    refute_includes html, "⚜️"
  end

  test "selection and lock wiring survive the restyle" do
    html = render_card(team_double)
    assert_includes html, "toggleSelection('42')"
    assert_includes html, "is-selected"
  end

  test "week opponents still render under the team" do
    html = render_card(team_double)
    assert_includes html, "IND"
    assert_includes html, "DAL"
    assert_includes html, "bye"
    assert_includes html, "Points"
  end
end
