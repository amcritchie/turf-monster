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
    attachment = landing_page&.og_image
    attachment = site_setting.default_og_image unless attachment&.attached?

    if attachment&.attached?
      url = attachment.url
      # Public S3 returns an absolute permanent URL already; Disk (local/test)
      # returns a host-relative path that an unfurler needs absolutized.
      return url if url.to_s.start_with?("http")
      return "#{request.base_url}#{url}"
    end

    "#{request.base_url}/og.png"
  end

  # True when neither a landing-page nor a site-default image is attached — the
  # layout uses this to decide whether to emit the fixed 1200x630 dimensions
  # (only valid for the static og.png; uploads may be any size).
  def og_image_default?(landing_page = nil)
    !(landing_page&.og_image&.attached? || site_setting.default_og_image.attached?)
  end

  def og_title(override = nil)
    override.presence ||
      site_setting.default_og_title.presence ||
      DEFAULT_OG_TITLE
  end

  def og_description(override = nil)
    override.presence ||
      site_setting.default_og_description.presence ||
      DEFAULT_OG_DESCRIPTION
  end

  private

  # Memoize per request — the layout calls several of these helpers per render.
  def site_setting
    @_og_site_setting ||= SiteSetting.instance
  end
end
