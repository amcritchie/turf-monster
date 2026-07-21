require "test_helper"

class TeamColorsHelperTest < ActionView::TestCase
  include TeamColorsHelper

  TeamDouble = Struct.new(:color_primary, :color_secondary, :color_text_light, keyword_init: true)

  # --- normalize_hex ---

  test "normalize_hex accepts #-prefixed, bare, and short hex" do
    assert_equal "#241773", normalize_hex("#241773")
    assert_equal "#241773", normalize_hex("241773")
    assert_equal "#ffffff", normalize_hex("#FFF")
  end

  test "normalize_hex rejects garbage and blanks" do
    assert_nil normalize_hex(nil)
    assert_nil normalize_hex("")
    assert_nil normalize_hex("not-a-color")
    assert_nil normalize_hex("#12345")
  end

  # --- darken / lighten ---

  test "darken moves toward black and lighten toward white" do
    assert_equal "#000000", darken_hex("#808080", 1.0)
    assert_equal "#ffffff", lighten_hex("#808080", 1.0)
    # identity at amount 0
    assert_equal "#3366cc", darken_hex("#3366cc", 0.0)
  end

  # --- contrast ---

  test "contrast_ratio spans the full 1..21 range" do
    assert_in_delta 21.0, contrast_ratio("#000000", "#ffffff"), 0.05
    assert_in_delta 1.0, contrast_ratio("#123456", "#123456"), 0.001
  end

  # --- accent: the crux, keeping near-black secondaries legible ---

  test "team_accent keeps a well-contrasting secondary" do
    # Packers: dark-green primary, gold secondary reads great → keep the gold.
    assert_equal "#ffb612", team_accent("#203731", "#ffb612", false)
  end

  test "team_accent uses a low-contrast secondary as-is (curated brand choice)" do
    # Bills red on royal blue is the team's own identity — used verbatim, not
    # swapped for a higher-contrast tint.
    assert_equal "#c60c30", team_accent("#00338d", "#c60c30", false)
    # Chargers gold on powder blue, likewise.
    assert_equal "#ffc20e", team_accent("#0080c6", "#ffc20e", false)
  end

  test "team_accent on a light-forward card keeps a dark readable secondary" do
    # Saints: gold primary, near-black secondary reads great → keep it dark.
    assert_equal "#101820", team_accent("#d3bc8d", "#101820", true)
  end

  test "team_accent falls back when a team has no secondary" do
    accent = team_accent("#97233f", nil, false)
    assert_match(/\A#[0-9a-f]{6}\z/, accent)
    assert_operator contrast_ratio(accent, "#97233f"), :>=, TeamColorsHelper::ACCENT_MIN_CONTRAST
  end

  # --- palette: the whole card contract ---

  test "dark team gets white foreground and a team gradient" do
    pal = team_card_palette(TeamDouble.new(color_primary: "#241773", color_secondary: "#9e7c0c", color_text_light: false))
    assert_equal TeamColorsHelper::LIGHT_FG, pal[:fg]
    assert_includes pal[:gradient], "linear-gradient"
    assert_includes pal[:fg_soft], "rgba(255, 255, 255"
  end

  test "light-forward team gets dark foreground" do
    pal = team_card_palette(TeamDouble.new(color_primary: "#d3bc8d", color_secondary: "#101820", color_text_light: true))
    assert_equal TeamColorsHelper::DARK_FG, pal[:fg]
    assert_equal "#101820", pal[:accent]
    assert_includes pal[:fg_soft], "rgba(15, 18, 22"
  end

  test "palette exposes exactly the keys the card and picks sidebar consume" do
    # The board cards, the cart rows, and the compact pick chips all read these
    # keys — renaming one silently breaks a consumer. Lock the contract.
    pal = team_card_palette(TeamDouble.new(color_primary: "#241773", color_secondary: "#9e7c0c", color_text_light: false))
    assert_equal %i[gradient fg fg_soft fg_faint border divider accent mascot_shadow].sort, pal.keys.sort
  end

  test "mascot_shadow outlines a low-contrast accent for legibility" do
    # Dark accent (Falcons black) → light halo; light accent (gold) → dark halo.
    assert_includes mascot_shadow("#000000"), "255, 255, 255"
    assert_includes mascot_shadow("#ffd700"), "rgba(0, 0, 0"
    assert_equal "none", mascot_shadow(nil)
  end

  test "palette survives a team with no brand colors" do
    pal = team_card_palette(TeamDouble.new(color_primary: nil, color_secondary: nil, color_text_light: nil))
    assert_includes pal[:gradient], "linear-gradient"
    assert_equal TeamColorsHelper::LIGHT_FG, pal[:fg]
    assert_match(/\A#[0-9a-f]{6}\z/, pal[:accent])
  end
end
