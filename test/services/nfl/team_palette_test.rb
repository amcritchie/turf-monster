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

  test "apply! recolors only existing rows and returns the count" do
    bal = Team.create!(name: "Recolor Ravens", slug: "recolor-ravens", short_name: "BAL",
                       league: "nfl", sport: "football", color_secondary: "#000000")

    count = Nfl::TeamPalette.apply!(Team.where(short_name: "BAL"))

    assert_equal 1, count, "only the BAL row in scope is recolored"
    assert_equal "#9E7C0C", bal.reload.color_secondary, "Ravens mascot becomes gold"
    assert_equal "#C60C30", bal.color_alt_light,        "red kept as alt-light"
  end
end
