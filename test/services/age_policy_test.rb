require "test_helper"

class AgePolicyTest < ActiveSupport::TestCase
  test "minimum_age defaults to 18 for unknown/nil states" do
    assert_equal 18, AgePolicy.minimum_age("CO")
    assert_equal 18, AgePolicy.minimum_age(nil)
    assert_equal 18, AgePolicy.minimum_age("")
    assert_equal 18, AgePolicy.minimum_age("ZZ")
  end

  test "minimum_age reflects the 19+ and 21+ exception states (case-insensitive)" do
    assert_equal 19, AgePolicy.minimum_age("AL")
    assert_equal 19, AgePolicy.minimum_age("ne")
    assert_equal 21, AgePolicy.minimum_age("IA")
    assert_equal 21, AgePolicy.minimum_age("MA")
    assert_equal 21, AgePolicy.minimum_age("va")
  end

  test "age_in_years is birthday-aware" do
    today = Date.new(2026, 6, 12)
    assert_equal 26, AgePolicy.age_in_years(Date.new(2000, 6, 12), today: today) # birthday today
    assert_equal 25, AgePolicy.age_in_years(Date.new(2000, 6, 13), today: today) # birthday tomorrow
    assert_equal 26, AgePolicy.age_in_years(Date.new(2000, 6, 11), today: today) # birthday yesterday
  end

  test "old_enough? gates on the state minimum" do
    today = Date.new(2026, 6, 12)
    assert AgePolicy.old_enough?(Date.new(2008, 6, 12), "CO", today: today)      # 18 in CO(18)
    assert_not AgePolicy.old_enough?(Date.new(2008, 6, 13), "CO", today: today)  # 17 → no
    assert_not AgePolicy.old_enough?(Date.new(2008, 6, 12), "IA", today: today)  # 18 in IA(21) → no
    assert AgePolicy.old_enough?(Date.new(2005, 6, 12), "IA", today: today)      # 21 in IA(21)
  end

  test "old_enough? rejects nil and future dates" do
    assert_not AgePolicy.old_enough?(nil, "CO")
    assert_not AgePolicy.old_enough?(Date.current + 1, "CO")
  end
end
