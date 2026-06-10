module Cdp
  # Shared gate for every CDP ramp endpoint (docs/CDP_RAMP_INTEGRATION.md §2):
  # ENABLE_CDP_RAMP is the kill-switch. The routes stay drawn so flipping the
  # env var (no deploy) turns the feature off — when off, every endpoint 404s
  # as if it doesn't exist. PREPENDED so even unauthenticated requests see the
  # 404 (not a login redirect): a dark feature advertises no surface at all.
  class BaseController < ApplicationController
    prepend_before_action :require_cdp_ramp_enabled

    private

    def require_cdp_ramp_enabled
      head :not_found unless AppFlags.cdp_ramp?
    end
  end
end
