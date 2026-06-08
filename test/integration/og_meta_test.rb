require "test_helper"

# End-to-end wiring: the og:image/title/description that OgHelper resolves
# actually reach the rendered <head> in BOTH layouts (application + landing).
class OgMetaTest < ActionDispatch::IntegrationTest
  setup do
    SiteSetting.instance.update!(default_og_title: nil, default_og_description: nil)
    SiteSetting.instance.default_og_image.purge if SiteSetting.instance.default_og_image.attached?
  end

  def og_image_content
    css_select("meta[property='og:image']").first["content"]
  end

  # --- application layout (faucet is a public GET on the app layout) ---

  test "application layout falls back to the static og.png by default" do
    get faucet_path
    assert_response :success
    assert og_image_content.end_with?("/og.png"), "expected static fallback, got #{og_image_content}"
    # Static fallback is the only case that emits fixed dimensions.
    assert_select "meta[property='og:image:width'][content='1200']"
  end

  test "application layout uses the SiteSetting default image when one is uploaded" do
    SiteSetting.instance.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "site-og.png", content_type: "image/png"
    )
    get faucet_path
    assert_response :success
    assert_not og_image_content.end_with?("/og.png"), "expected the uploaded default, got the static fallback"
    # Uploaded images have unknown dimensions — no fixed width/height emitted.
    assert_select "meta[property='og:image:width']", count: 0
  end

  test "admin-set default description fills in; a page's own title still wins" do
    SiteSetting.instance.update!(
      default_og_title: "Admin Title", default_og_description: "Admin Description"
    )
    get faucet_path
    assert_response :success
    # Faucet sets its own title (page-specific wins over the site default) but
    # no description, so the admin-set default description fills in.
    assert_select "meta[property='og:description'][content='Admin Description']"
    assert_select "meta[property='og:title'][content='Devnet Faucet — Turf Monster']"
    assert_select "meta[property='og:title'][content='Admin Title']", count: 0
  end

  # --- landing layout (per-page override wins) ---

  test "landing layout uses the per-page og image over the site default" do
    SiteSetting.instance.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "site-og.png", content_type: "image/png"
    )
    lp = landing_pages(:launch)
    lp.og_image.attach(
      io: file_fixture("banner_wide.png").open, filename: "page-og.png", content_type: "image/png"
    )

    get landing_page_path(lp)
    assert_response :success
    # The Disk (test) redirect URL ends with the blob filename — assert the
    # per-page blob won over the site default (avoids signature/host timing
    # flakiness from comparing freshly-signed URLs).
    assert_includes og_image_content, "page-og.png"
    assert_not_includes og_image_content, "site-og.png"
  end

  test "landing layout falls back to the static og.png when nothing is uploaded" do
    get landing_page_path(landing_pages(:launch))
    assert_response :success
    assert og_image_content.end_with?("/og.png")
  end
end
