require "test_helper"

class Admin::SiteConfigsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin   = users(:alex)
    @user    = users(:jordan)
    @contest = contests(:one)
  end

  test "show requires admin" do
    log_in_as(@user)
    get admin_site_config_path
    assert_response :redirect
  end

  test "show requires login" do
    get admin_site_config_path
    assert_response :redirect
  end

  test "show renders for admin" do
    log_in_as(@admin)
    get admin_site_config_path
    assert_response :success
    assert_select "h1", text: "Site Config"
    assert_select "form"
  end

  test "show surfaces a settled explicit pick alongside its resolved fallback" do
    settled = Contest.create!(
      name: "Settled Pick", status: :settled, contest_type: "small",
      entry_fee_cents: 1900, max_entries: 5, slate: slates(:one),
      starts_at: 1.week.from_now, rank: 100
    )
    SeasonConfig.set_main_contest!(settled)

    log_in_as(@admin)
    get admin_site_config_path
    assert_response :success
    # The "Admin-set" line shows the settled pick even though main_contest
    # masks it; the page lets the admin see the mismatch.
    assert_select "div", text: /Settled Pick/
  end

  test "update sets main_contest" do
    log_in_as(@admin)
    assert_nil SeasonConfig.main_contest_explicit

    patch admin_site_config_path, params: { main_contest_id: @contest.id }

    assert_redirected_to admin_site_config_path
    assert_equal @contest, SeasonConfig.main_contest_explicit
  end

  test "update with empty value clears main_contest" do
    SeasonConfig.set_main_contest!(@contest)
    assert_equal @contest, SeasonConfig.main_contest_explicit

    log_in_as(@admin)
    patch admin_site_config_path, params: { main_contest_id: "" }

    assert_redirected_to admin_site_config_path
    assert_nil SeasonConfig.main_contest_explicit
  end

  test "update rejects non-admin" do
    log_in_as(@user)
    patch admin_site_config_path, params: { main_contest_id: @contest.id }
    assert_response :redirect
    assert_nil SeasonConfig.main_contest_explicit
  end
end
