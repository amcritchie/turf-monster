require "test_helper"

class LandingPagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @active   = landing_pages(:launch) # active, contest: one
    @inactive = landing_pages(:draft)  # inactive, no contest
    @admin    = users(:alex)
  end

  test "shows an active landing page to anyone" do
    get landing_page_path(@active)
    assert_response :success
    assert_select "h1", text: @active.headline
  end

  test "renders the CTA pointing at the contest lobby" do
    get landing_page_path(@active)
    assert_select "a[href=?]", contest_lobby_path(@active.contest.slug), text: @active.cta_label
  end

  test "visiting seeds the reference cookie with the slug" do
    get landing_page_path(@active)
    assert_equal @active.slug, cookies[:reference]
  end

  test "an existing reference cookie is not overwritten by a landing page" do
    get faucet_path, params: { reference: "campaign-x" }
    get landing_page_path(@active)
    assert_equal "campaign-x", cookies[:reference]
  end

  test "inactive page is hidden from the public" do
    get landing_page_path(@inactive)
    assert_redirected_to root_path
  end

  test "inactive page is visible to admins for preview" do
    log_in_as(@admin)
    get landing_page_path(@inactive)
    assert_response :success
  end

  test "unknown slug redirects" do
    get landing_page_path("does-not-exist")
    assert_redirected_to root_path
  end
end
