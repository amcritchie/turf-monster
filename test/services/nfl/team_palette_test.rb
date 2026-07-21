require "test_helper"

class Nfl::TeamPaletteTest < ActiveSupport::TestCase
  test "PALETTE covers all 32 teams with valid hex primary and secondary" do
    assert_equal 32, Nfl::TeamPalette::PALETTE.size
    Nfl::TeamPalette::PALETTE.each do |abbr, colors|
      assert_match(/\A#[0-9A-F]{6}\z/, colors[:primary], "#{abbr} primary")
      assert_match(/\A#[0-9A-F]{6}\z/, colors[:secondary], "#{abbr} secondary")
    end
  end

  test "attributes_for collapses a blank alt slot to nil" do
    attrs = Nfl::TeamPalette.attributes_for("NYJ") # simple two-color team
    assert_equal "#FFFFFF", attrs[:color_secondary]
    assert_nil attrs[:color_alt_light]
    assert_nil attrs[:color_alt_dark]
  end

  test "apply! recolors NFL rows only, never a same-abbreviation non-NFL team" do
    nfl_bal = Team.create!(name: "Recolor Ravens", slug: "recolor-ravens", short_name: "BAL",
                           league: "nfl", sport: "football", color_secondary: "#000000")
    other_bal = Team.create!(name: "Balkan United", slug: "balkan-united", short_name: "BAL",
                             league: "fifa", sport: "soccer", color_secondary: "#000000")

    count = Nfl::TeamPalette.apply! # default scope = Team.nfl

    assert_equal 1, count, "only the NFL BAL row is recolored"
    assert_equal "#9E7C0C", nfl_bal.reload.color_secondary, "NFL Ravens becomes gold"
    assert_equal "#C60C30", nfl_bal.color_alt_light,        "red kept as alt-light"
    assert_equal "#000000", other_bal.reload.color_secondary, "non-NFL BAL is untouched"
  end
end
