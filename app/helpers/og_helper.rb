# Resolves link-preview (og/twitter) metadata for the layouts.
#
# Resolution order (most specific wins, static asset is the ultimate fallback
# so a preview NEVER breaks even with nothing uploaded):
#
#   image: landing_page.og_image  ->  SiteSetting default_og_image  ->  /og.png
#   title: content_for(:title)    ->  SiteSetting default_og_title  ->  hardcoded
#   desc:  content_for(:meta_..)  ->  SiteSetting default_og_desc.   ->  hardcoded
#
# `landing_page` is nil on the standard application layout; the landing layout
# passes the current @landing_page so an operator can override per funnel page.
module OgHelper
  # Fallbacks baked into the layouts before this helper existed; kept here as
  # the last resort when SiteSetting has no admin-set default.
  DEFAULT_OG_TITLE = "Turf Totals — Solana Pick’em Contests".freeze
  DEFAULT_OG_DESCRIPTION =
    "Turf Totals: Solana-powered World Cup pick’em contests. Pick 6 matchups, " \
    "stack Turf Scores, and win prizes settled on-chain.".freeze

  def og_image_url(landing_page = nil)
    # Per-funnel override wins (queries the landing page's attachment).
    lp_image = landing_page&.og_image
    return absolute_og_url(lp_image) if lp_image&.attached?

    defaults = SiteSetting.og_defaults
    # Prod: cached permanent public URL — no query. Dev/test (Disk): the cached
    # URL is nil, so resolve the attachment live.
    return defaults[:image_url] if defaults[:image_url]
    return absolute_og_url(SiteSetting.instance.default_og_image) if defaults[:image_attached]

    "#{request.base_url}/og.png"
  end

  # True when neither a landing-page nor a site-default image is attached — the
  # layout uses this to decide whether to emit the fixed 1200x630 dimensions
  # (only valid for the static og.png; uploads may be any size).
  def og_image_default?(landing_page = nil)
    !(landing_page&.og_image&.attached? || SiteSetting.og_defaults[:image_attached])
  end

  def og_title(override = nil)
    override.presence || SiteSetting.og_defaults[:title] || DEFAULT_OG_TITLE
  end

  def og_description(override = nil)
    override.presence || SiteSetting.og_defaults[:description] || DEFAULT_OG_DESCRIPTION
  end

  private

  # Public S3 (prod) returns a permanent absolute URL directly — exactly what an
  # unfurler needs. Disk (dev/test) has no public URL, and `attachment.url` there
  # raises without ActiveStorage::Current.url_options (unset in integration
  # tests), so build an absolute URL from a host-relative blob path instead — no
  # Current dependency, still ends with the filename.
  def absolute_og_url(attachment)
    if attachment.blob.service.public?
      attachment.url
    else
      "#{request.base_url}#{rails_blob_path(attachment)}"
    end
  end
end
