require "test_helper"

# Component tier for the four-color palette on /teams: each populated color slot
# renders a swatch tagged with its role emoji, and a legend explains them.
class TeamsPaletteTest < ActionDispatch::IntegrationTest
  test "a four-color team shows a swatch per slot with its role emoji" do
    four = Team.create!(name: "Palette Four", slug: "palette-four", short_name: "PF4",
                        league: "nfl", sport: "football",
                        color_primary: "#123456", color_secondary: "#654321",
                        color_alt_light: "#FFFFFF", color_alt_dark: "#000000")
    get teams_path
    assert_response :success
    assert_select "a[href=?]", team_path(four) do
      assert_select "[title=?]", "🎨 #123456"
      assert_select "[title=?]", "🔤 #654321"
      assert_select "[title=?]", "☀️ #FFFFFF"
      assert_select "[title=?]", "🌙 #000000"
    end
  end

  test "a team without alt colors shows only primary and secondary swatches" do
    two = Team.create!(name: "Palette Two", slug: "palette-two", short_name: "PF2",
                       league: "nfl", sport: "football",
                       color_primary: "#0A0A0A", color_secondary: "#FAFAFA")
    get teams_path
    assert_select "a[href=?]", team_path(two) do
      assert_select "[title=?]", "🎨 #0A0A0A"
      assert_select "[title^=?]", "☀️", count: 0
      assert_select "[title^=?]", "🌙", count: 0
    end
  end

  test "the page carries a legend for the four color roles" do
    get teams_path
    assert_match "🎨 background", response.body
    assert_match "🔤 text", response.body
    assert_match "☀️ alt light", response.body
    assert_match "🌙 alt dark", response.body
  end
end
