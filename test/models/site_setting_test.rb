require "test_helper"

class SiteSettingTest < ActiveSupport::TestCase
  test "instance returns the singleton, creating it once" do
    first  = SiteSetting.instance
    second = SiteSetting.instance
    assert_equal first.id, second.id
    assert_equal "site-setting", first.slug
    assert_equal 1, SiteSetting.where(slug: "site-setting").count
  end

  test "name_slug is pinned regardless of other attributes" do
    setting = SiteSetting.instance
    setting.update!(default_og_title: "Something Else")
    assert_equal "site-setting", setting.reload.slug
  end

  test "can attach a default og image" do
    setting = SiteSetting.instance
    assert_not setting.default_og_image.attached?

    setting.default_og_image.attach(
      io: file_fixture("banner.png").open, filename: "og.png", content_type: "image/png"
    )
    assert setting.reload.default_og_image.attached?
  end

  test "uses the Disk test service for attachments in the test env" do
    # OgImageAttachable picks :test (Disk) in test so the suite never touches
    # S3 or needs AWS creds.
    assert_equal :test, OgImageAttachable::PUBLIC_OG_SERVICE
  end

  test "og_defaults caches the resolution inputs and bust clears them" do
    # The suite's cache is a null_store (no caching); swap in a real store to
    # exercise the cache hit + the bust the og:image admin flow relies on.
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    SiteSetting.instance.update_column(:default_og_title, "First") # update_column: no callbacks/bust
    assert_equal "First", SiteSetting.og_defaults[:title]

    SiteSetting.instance.update_column(:default_og_title, "Second")
    assert_equal "First", SiteSetting.og_defaults[:title], "should still be cached"

    SiteSetting.bust_og_defaults_cache!
    assert_equal "Second", SiteSetting.og_defaults[:title], "fresh read after bust"
  ensure
    Rails.cache = original
  end
end
