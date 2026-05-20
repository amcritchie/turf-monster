require "test_helper"

class AdminControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)   # role: admin
    @user  = users(:jordan) # regular user
  end

  # --- hub (Link Hub) ---

  test "hub renders for admins" do
    log_in_as(@admin)
    get admin_hub_path
    assert_response :success
    assert_select "h1", text: "Link Hub"
    assert_select "h2", text: "Design"              # hub section
    assert_select "h2", text: "Sports"              # hub section
    assert_select "a[href=?]", admin_seasons_path   # a navigation link moved off the gear
    assert_select "button", text: "Refresh Balance" # an action control moved off the gear
  end

  test "hub marks reviewed and flagged links" do
    log_in_as(@admin)
    get admin_hub_path
    assert_response :success
    reviewed = [contests_path, admin_seasons_path, slates_path, admin_geo_path, error_logs_path, "/admin/jobs"]
    flagged  = [admin_formula_slates_path, new_contest_path, formula_report_slates_path, generator_contests_path]
    reviewed.each { |path| assert_select "a[href=?][data-status=?]", path, "reviewed" }
    flagged.each  { |path| assert_select "a[href=?][data-status=?]", path, "flagged" }

    assert_select "span", text: "Not added to the gear"
  end

  test "hub redirects non-admins" do
    log_in_as(@user)
    get admin_hub_path
    assert_response :redirect
  end

  test "hub redirects anonymous visitors" do
    get admin_hub_path
    assert_response :redirect
  end

  # --- navbar gear dropdown ---

  test "navbar gear dropdown renders for admins" do
    log_in_as(@admin)
    get faucet_path
    assert_response :success
    assert_select "a[href=?]", admin_seasons_path  # a curated link inside the gear
    assert_select "a[href=?]", slates_path         # FIFA: Slate Formula link
    assert_select "a[href=?]", admin_geo_path      # Admin: Geo Settings link
    assert_select "a[href=?]", error_logs_path     # Admin: Error Logs link
    assert_select "a[href=?]", "/admin/jobs"       # Admin: Jobs link
    assert_select "a[href=?]", admin_hub_path      # full Link Hub link inside the gear
  end

  test "navbar gear dropdown hidden from non-admins" do
    log_in_as(@user)
    get faucet_path
    assert_response :success
    assert_select "a[href=?]", admin_hub_path, count: 0
  end
end
