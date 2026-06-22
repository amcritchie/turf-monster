require "test_helper"

# Regression guard for the iMessage/link-preview bug: `allow_browser versions:
# :modern` 406s old-Safari UAs, and Apple's link-preview fetcher presents a
# pinned old-Safari UA — so without the public-page exemption, shared links
# never unfurl. These assert the exemption holds (public preview pages serve
# 200 to an old UA) while the guard still protects the rest of the app.
class LinkPreviewBrowserGuardTest < ActionDispatch::IntegrationTest
  # Safari 14 — below `:modern`, so allow_browser 406s it (this is what Apple's
  # LinkPresentation fetcher looks like).
  OLD_SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 Safari/605.1.15".freeze
  MODERN     = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15".freeze

  test "landing page serves og tags to an old-browser link-preview fetcher" do
    get landing_page_path(landing_pages(:launch)), headers: { "HTTP_USER_AGENT" => OLD_SAFARI }
    assert_response :success
    assert_match %r{<meta property="og:image"}, response.body
  end

  test "contest show serves og tags to an old-browser link-preview fetcher" do
    get "/contests/#{contests(:one).slug}", headers: { "HTTP_USER_AGENT" => OLD_SAFARI }
    assert_response :success
    assert_match %r{<meta property="og:image"}, response.body
  end

  test "legal and compliance pages serve an old-browser preview fetcher" do
    # Underwriting compliance: these URLs are pasted into merchant
    # applications and emails — they must unfurl and never 406 a visitor.
    ["/terms", "/privacy", "/about", "/contact",
     "/responsible-gaming", "/state-eligibility"].each do |path|
      get path, headers: { "HTTP_USER_AGENT" => OLD_SAFARI }
      assert_response :success, "#{path} should be exempt from the browser guard"
    end
  end

  test "allow_browser guard still 406s an old browser on a non-preview page" do
    get "/faucet", headers: { "HTTP_USER_AGENT" => OLD_SAFARI }
    assert_response :not_acceptable
  end

  test "a modern browser is never blocked on a non-preview page" do
    get "/faucet", headers: { "HTTP_USER_AGENT" => MODERN }
    assert_response :success
  end
end
