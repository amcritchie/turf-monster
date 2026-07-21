require "test_helper"

# Integration tier: colors are a function of seeding. The NFL seed assigns the
# full four-color palette and is idempotent — reseeding corrects a drifted color
# without duplicating team rows (the operator's "reseed to correct" guarantee).
class NflTeamColorsSeedTest < ActiveSupport::TestCase
  def seed!
    silence_warnings { load Rails.root.join("db/seeds/nfl_2026.rb") }
  end

  test "seed assigns the four-color palette per the reorganized rules" do
    seed!

    bills = Team.find_by!(slug: "buffalo-bills")
    assert_equal "#00338D", bills.color_primary,   "primary = background"
    assert_equal "#C60C30", bills.color_secondary, "secondary = red mascot text"
    assert_equal "#FFFFFF", bills.color_alt_light, "white kept as alt-light"
    assert_equal "#041E42", bills.color_alt_dark,  "navy kept as alt-dark"

    assert_equal "#9E7C0C", Team.find_by!(slug: "baltimore-ravens").color_secondary, "Ravens mascot = gold"
    assert_equal "#B3995D", Team.find_by!(slug: "san-francisco-49ers").color_secondary, "49ers mascot = gold"
    assert_nil Team.find_by!(slug: "new-york-jets").color_alt_light, "Jets are a simple two-color team"
    assert Team.find_by!(slug: "new-orleans-saints").color_text_light, "Saints kept light-forward"
  end

  test "reseeding corrects a drifted color without duplicating teams" do
    seed!
    bills = Team.find_by!(slug: "buffalo-bills")
    bills.update!(color_secondary: "#000000") # simulate a bad/manual edit

    seed!

    assert_equal 1, Team.where(slug: "buffalo-bills").count, "reseed must not duplicate a team"
    assert_equal "#C60C30", bills.reload.color_secondary, "reseed restores the canonical color"
  end
end
