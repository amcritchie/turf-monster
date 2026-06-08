require "test_helper"

class OgHelperTest < ActionView::TestCase
  include OgHelper

  setup do
    # Start from a clean singleton each test (no admin-set defaults).
    SiteSetting.instance.update!(default_og_title: nil, default_og_description: nil)
    # Disk (test) service .url needs a host to build the blob URL.
    ActiveStorage::Current.url_options = { host: "test.host", protocol: "http" }
  end

  # --- og_title ---

  test "og_title prefers a page override" do
    SiteSetting.instance.update!(default_og_title: "Site Default Title")
    assert_equal "Page Title", og_title("Page Title")
  end

  test "og_title falls back to the SiteSetting default" do
    SiteSetting.instance.update!(default_og_title: "Site Default Title")
    assert_equal "Site Default Title", og_title(nil)
  end

  test "og_title falls back to the hardcoded default last" do
    assert_equal OgHelper::DEFAULT_OG_TITLE, og_title(nil)
    assert_equal OgHelper::DEFAULT_OG_TITLE, og_title("")
  end

  # --- og_description (separate single-state cases: the helper memoizes
  # SiteSetting per request, so mid-test mutation wouldn't be observed) ---

  test "og_description prefers a page override" do
    SiteSetting.instance.update!(default_og_description: "Site Desc")
    assert_equal "Page Desc", og_description("Page Desc")
  end

  test "og_description falls back to the SiteSetting default" do
    SiteSetting.instance.update!(default_og_description: "Site Desc")
    assert_equal "Site Desc", og_description(nil)
  end

  test "og_description falls back to the hardcoded default last" do
    assert_equal OgHelper::DEFAULT_OG_DESCRIPTION, og_description(nil)
  end

  # --- og_image_url resolution order ---
  # (The static-asset fallback path needs request.base_url and is covered by
  # the integration test OgMetaTest, which renders a real page.)

  test "og_image_url prefers the landing page image over the site default" do
    SiteSetting.instance.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "site.png", content_type: "image/png"
    )
    lp = landing_pages(:launch)
    lp.og_image.attach(
      io: file_fixture("banner_wide.png").open, filename: "page.png", content_type: "image/png"
    )

    # The landing page's own blob wins. The resolved URL is absolute and ends
    # with the page blob's filename, not the site default's (Disk path in test,
    # permanent public S3 url in prod — both carry the filename).
    url = og_image_url(lp)
    assert url.start_with?("http"), "expected absolute url, got #{url}"
    assert_includes url, "page.png"
    assert_not_includes url, "site.png"
  end

  test "og_image_url falls back to the site default when the page has none" do
    SiteSetting.instance.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "site.png", content_type: "image/png"
    )
    lp = landing_pages(:launch) # no og_image attached
    url = og_image_url(lp)
    assert url.start_with?("http"), "expected absolute url, got #{url}"
    assert_includes url, "site.png"
  end

  # --- og_image_default? (single-state cases, per the memoization note above) ---

  test "og_image_default? is true when nothing is attached anywhere" do
    assert og_image_default?(landing_pages(:launch))
  end

  test "og_image_default? is false when the site default image is attached" do
    SiteSetting.instance.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "site.png", content_type: "image/png"
    )
    assert_not og_image_default?(landing_pages(:launch))
  end

  test "og_image_default? is false when the landing page has its own image" do
    lp = landing_pages(:launch)
    lp.og_image.attach(
      io: file_fixture("banner_wide.png").open, filename: "page.png", content_type: "image/png"
    )
    assert_not og_image_default?(lp)
  end
end
