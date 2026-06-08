# Shared resolver for the Active Storage service that backs og:image
# (link-preview) attachments.
#
# Why a constant and not just `service: :amazon_public` on each model:
# has_one_attached's `service:` option is a LITERAL service name, resolved once
# when the macro runs at class load. It can't switch per-env on its own. We
# need three different services depending on the environment (test must stay on
# Disk so the suite never touches S3 or needs AWS creds; prod/dev need the
# matching public-read bucket), so the env switch has to be computed here.
#
# This mirrors the private-service selection in config/environments/*.rb
# (`config.active_storage.service`), but points at the PUBLIC (`public: true`)
# variants from config/storage.yml so `attachment.url` is a permanent, absolute
# S3 URL — unfurlers (Apple/Twitter/Slack) cache the og:image URL, and a signed
# expiring URL from the private `amazon` service would break the preview once
# the signature lapses.
#
#   test         -> :test               (Disk, tmp/storage — no network/creds)
#   production    -> :amazon_public       (turf-monster-production, public-read)
#   development   -> :amazon_public_dev   (turf-monster-dev) when AWS creds are
#                    present, else :local (Disk) for a keyless local checkout
module OgImageAttachable
  extend ActiveSupport::Concern

  PUBLIC_OG_SERVICE =
    if Rails.env.test?
      :test
    elsif Rails.env.production?
      :amazon_public
    elsif ENV["AWS_ACCESS_KEY_ID"].present?
      :amazon_public_dev
    else
      :local
    end
end
