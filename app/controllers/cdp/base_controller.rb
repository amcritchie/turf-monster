module Cdp
  # Shared gate for every CDP ramp endpoint (docs/CDP_RAMP_INTEGRATION.md §2):
  # ENABLE_CDP_RAMP is the kill-switch. The routes stay drawn so flipping the
  # env var (no deploy) turns the feature off — when off, every endpoint 404s
  # as if it doesn't exist. PREPENDED so even unauthenticated requests see the
  # 404 (not a login redirect): a dark feature advertises no surface at all.
  class BaseController < ApplicationController
    skip_before_action :require_authentication
    prepend_before_action :enforce_cdp_origin_policy
    prepend_before_action :require_cdp_ramp_enabled
    before_action :require_cdp_authentication, unless: :cdp_preflight?

    def preflight
      head :no_content
    end

    private

    def require_cdp_ramp_enabled
      head :not_found unless AppFlags.cdp_ramp?
    end

    # CDP security review (2026-06): ramp endpoints must never turn an
    # unauthenticated raw client into a browser-style redirect that later lands
    # on a 200 app page. These are API endpoints, so reject directly for every
    # requested format.
    def require_cdp_authentication
      return if logged_in?

      render json: { error: "unauthenticated" }, status: :unauthorized
    end

    # Strict, explicit CORS for the CDP API surface. Same-origin browser calls
    # carry no Origin and pass through to auth. Cross-origin callers only get a
    # response when their Origin is in this allowlist.
    def enforce_cdp_origin_policy
      origin = request.headers["Origin"].to_s
      return if origin.blank?

      unless cdp_allowed_origins.include?(origin)
        head :forbidden
        return
      end

      headers["Access-Control-Allow-Origin"] = origin
      headers["Access-Control-Allow-Credentials"] = "true"
      headers["Access-Control-Allow-Methods"] = "POST, GET, OPTIONS"
      headers["Access-Control-Allow-Headers"] = "Accept, Content-Type, X-CSRF-Token"
      headers["Vary"] = [headers["Vary"], "Origin"].compact.join(", ")
    end

    def cdp_allowed_origins
      configured = ENV["CDP_ALLOWED_ORIGINS"].to_s.split(",").map(&:strip).reject(&:blank?)
      return configured if configured.any?

      origins = ["https://app.turfmonster.media"]
      origins << "http://localhost:3100" unless Rails.env.production?
      origins
    end

    def cdp_preflight?
      request.request_method == "OPTIONS"
    end
  end
end
