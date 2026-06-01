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
    assert_select "h2", text: "Admin"               # hub section
    assert_select "a[href=?]", admin_seasons_path   # a navigation link moved off the gear
    assert_select "button", text: "Refresh Balance" # an action control moved off the gear
  end

  test "hub marks reviewed and flagged links" do
    log_in_as(@admin)
    get admin_hub_path
    assert_response :success
    reviewed = [contests_path, admin_seasons_path, slates_path, admin_geo_path, error_logs_path, "/admin/jobs"]
    flagged  = [admin_formula_slates_path, new_contest_path, formula_report_slates_path, generator_contests_path,
                admin_pending_transactions_path, admin_transactions_path]
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

  # --- Sidekiq Web admin gate (SidekiqAdminMiddleware) ---
  # Lazarus audit #17 / OPSEC-045: /admin/jobs must require BOTH admin? AND a
  # session whose token still matches the user's current session_token, so a
  # rotated/revoked session (e.g. after the email-change flow or a forced
  # re-login) loses Sidekiq Web access too — not just admin? alone.

  test "Sidekiq /admin/jobs denies non-admins (404)" do
    log_in_as(@user)
    get "/admin/jobs"
    assert_response :not_found
  end

  test "Sidekiq /admin/jobs denies a stale session_token (OPSEC-045)" do
    log_in_as(@admin)
    # Rotate the DB token so the session's stored token is now stale, as if the
    # admin re-authed elsewhere or an email change rotated it.
    @admin.update_column(:session_token, SecureRandom.hex(32))
    get "/admin/jobs"
    assert_response :not_found
  end

  test "Sidekiq /admin/jobs opens for an admin with a matching session token" do
    log_in_as(@admin)
    get "/admin/jobs"
    assert_not_equal 404, response.status, "a valid admin session must pass the gate"
  end
end
