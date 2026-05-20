require "test_helper"

class Admin::LandingPagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin        = users(:alex)
    @user         = users(:jordan)
    @landing_page = landing_pages(:launch)
  end

  test "index requires admin" do
    log_in_as(@user)
    get admin_landing_pages_path
    assert_response :redirect
  end

  test "index lists landing pages for admins" do
    log_in_as(@admin)
    get admin_landing_pages_path
    assert_response :success
    assert_select "td", text: @landing_page.name
  end

  test "new renders the form" do
    log_in_as(@admin)
    get new_admin_landing_page_path
    assert_response :success
  end

  test "create makes a landing page" do
    log_in_as(@admin)
    assert_difference "LandingPage.count", 1 do
      post admin_landing_pages_path, params: {
        landing_page: { name: "May Promo", headline: "Play now", contest_id: contests(:one).id, active: true }
      }
    end
    assert_redirected_to admin_landing_pages_path
    lp = LandingPage.find_by(name: "May Promo")
    assert lp.active?
    assert_equal contests(:one).id, lp.contest_id
  end

  test "create rejects an active page with no contest" do
    log_in_as(@admin)
    assert_no_difference "LandingPage.count" do
      post admin_landing_pages_path, params: { landing_page: { name: "Bad", active: true } }
    end
    assert_response :unprocessable_entity
  end

  test "update changes a landing page" do
    log_in_as(@admin)
    patch admin_landing_page_path(@landing_page), params: { landing_page: { headline: "New Headline" } }
    assert_redirected_to admin_landing_pages_path
    assert_equal "New Headline", @landing_page.reload.headline
  end

  test "destroy removes a landing page" do
    log_in_as(@admin)
    assert_difference "LandingPage.count", -1 do
      delete admin_landing_page_path(@landing_page)
    end
    assert_redirected_to admin_landing_pages_path
  end

  test "navbar exposes landing page links to admins" do
    log_in_as(@admin)
    get faucet_path
    assert_response :success
    assert_select "a[href=?]", admin_landing_pages_path         # Admin section → manager
    assert_select "a[href=?]", landing_page_path(@landing_page) # FIFA section → live page
  end

  test "the contest dropdown includes survivor contests" do
    Contest.create!(name: "Dropdown Survivor", game_type: "world_cup_survivor",
                    contest_type: "survivor_wc_free", status: "open")
    log_in_as(@admin)
    get new_admin_landing_page_path
    assert_response :success
    assert_select "select#landing_page_contest_id option", text: /Dropdown Survivor/
  end

  test "the form offers a background style choice" do
    log_in_as(@admin)
    get new_admin_landing_page_path
    assert_response :success
    assert_select "select#landing_page_background_style option", text: "Rotating blobs"
  end

  test "create accepts a background style" do
    log_in_as(@admin)
    post admin_landing_pages_path, params: {
      landing_page: { name: "Blobby Funnel", contest_id: contests(:one).id, active: true, background_style: "blobs" }
    }
    assert_redirected_to admin_landing_pages_path
    assert_equal "blobs", LandingPage.find_by(name: "Blobby Funnel").background_style
  end
end
