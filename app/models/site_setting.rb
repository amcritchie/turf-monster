# Site-wide singleton for link-preview (og:image) defaults.
#
# Mirrors SeasonConfig's singleton shape (one row, fetched via `.instance`,
# pinned to a hardcoded slug). Distinct from SeasonConfig — that's the on-chain
# Season pointer; this carries the marketing/unfurl defaults: the fallback
# og:image plus the default title/description used when a page doesn't set its
# own. Resolution + wiring into the layouts lives in OgHelper.
class SiteSetting < ApplicationRecord
  include Sluggable
  include OgImageAttachable

  # Public-read service so og:image resolves to a permanent absolute S3 URL.
  has_one_attached :default_og_image, service: OgImageAttachable::PUBLIC_OG_SERVICE

  def self.instance
    find_or_create_by(slug: "site-setting")
  end

  private

  def name_slug
    "site-setting"
  end
end
