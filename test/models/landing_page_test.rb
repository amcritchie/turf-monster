require "test_helper"

class LandingPageTest < ActiveSupport::TestCase
  test "valid with a name" do
    assert LandingPage.new(name: "Spring Promo").valid?
  end

  test "name is required" do
    lp = LandingPage.new(name: "")
    assert_not lp.valid?
    assert_includes lp.errors[:name], "can't be blank"
  end

  test "slug is generated from the name when blank" do
    lp = LandingPage.create!(name: "Spring Promo 2026")
    assert_equal "spring-promo-2026", lp.slug
  end

  test "an explicit slug is kept" do
    lp = LandingPage.create!(name: "Spring Promo", slug: "spring")
    assert_equal "spring", lp.slug
  end

  test "slug stays stable when the name changes" do
    lp = LandingPage.create!(name: "Spring Promo")
    lp.update!(name: "Renamed Promo")
    assert_equal "spring-promo", lp.slug
  end

  test "slug must be unique" do
    LandingPage.create!(name: "First", slug: "dupe")
    dup = LandingPage.new(name: "Second", slug: "dupe")
    assert_not dup.valid?
    assert_includes dup.errors[:slug], "has already been taken"
  end

  test "cannot be active without a contest" do
    lp = LandingPage.new(name: "No Contest", active: true)
    assert_not lp.valid?
    assert_includes lp.errors[:active], "can't be enabled without a contest selected"
  end

  test "can be active with a contest" do
    assert LandingPage.new(name: "With Contest", active: true, contest: contests(:one)).valid?
  end

  test "cta_label_display falls back to a default" do
    assert_equal "Enter the Contest", LandingPage.new.cta_label_display
    assert_equal "Go", LandingPage.new(cta_label: "Go").cta_label_display
  end

  test "signup_count counts users referenced by this slug" do
    lp = landing_pages(:launch)
    assert_equal 0, lp.signup_count
    users(:jordan).update!(reference: lp.slug)
    assert_equal 1, lp.signup_count
  end

  test "defaults to the gradient background" do
    lp = LandingPage.new
    assert_equal "gradient", lp.background_style
    assert_equal "gradient", lp.background_partial
  end

  test "a blobs page renders the blobs partial" do
    lp = LandingPage.new(background_style: "blobs")
    assert lp.blobs?
    assert_equal "blobs", lp.background_partial
  end

  test "a circles page renders the circles partial" do
    lp = LandingPage.new(background_style: "circles")
    assert lp.circles?
    assert_equal "circles", lp.background_partial
  end
end
