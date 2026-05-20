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

  test "renders the CTA pointing at the contest" do
    get landing_page_path(@active)
    assert_select "a[href=?]", contest_path(@active.contest.slug, scroll: 100), text: @active.cta_label
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

  test "a survivor contest funnel shows survivor copy and a free entry" do
    survivor = Contest.create!(name: "WC Survivor Test", game_type: "world_cup_survivor",
                               contest_type: "survivor_wc_free", status: "open")
    lp = LandingPage.create!(name: "Survivor Funnel", headline: "Last One Standing",
                             contest: survivor, active: true)
    get landing_page_path(lp)
    assert_response :success
    assert_select "p", text: "Win or draw to survive"       # survivor how-it-works step
    assert_select "p", text: "Pick 6 teams", count: 0 # not the Turf Totals copy
    assert_select "p", text: "Free"                         # $0 entry renders as Free
  end

  test "renders the gradient background by default" do
    get landing_page_path(@active)
    assert_response :success
    assert_select ".lp-bg"
  end

  test "renders the blob background when the page selects it" do
    @active.update!(background_style: "blobs")
    get landing_page_path(@active)
    assert_response :success
    assert_select ".lp-blobs svg"
    assert_select ".lp-bg", count: 0
  end

  test "renders the badge when set" do
    @active.update!(badge: "Alpha Test")
    get landing_page_path(@active)
    assert_response :success
    assert_select ".lp-badge", text: "Alpha Test"
  end

  test "renders no badge when the badge is blank" do
    get landing_page_path(@active) # launch fixture has no badge
    assert_response :success
    assert_select ".lp-badge", count: 0
  end
end
