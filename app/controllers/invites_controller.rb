# Referral / invite links — GET /i/:token. Handles REFERRAL-kind Studio::Links
# ONLY: capture the inviter into the attribution cookie + redirect to the link's
# target. Idempotent + reusable (referral links are never burned) and safe to
# prefetch.
#
# Intentionally NOT the engine's Studio::LinksController: that controller's POST
# #consume signs a recipient in / creates an account via the engine's generic
# sign_up_new, which has none of turf-monster's account-creation guards (legal-age
# attestation, reset_prior_session!, reference cap). Account creation must stay on
# the single audited path — MagicLinksController#consume. A non-referral token
# here is rejected, so /i can never become a second sign-in path.
class InvitesController < ApplicationController
  skip_before_action :require_authentication

  def show
    link = Studio::Link.find_by(token: params[:token])

    unless link&.kind == "referral" && link.live?
      return redirect_to root_path, alert: "That invite link is invalid or has expired."
    end

    inviter = link.linkable
    ref = (inviter.respond_to?(:slug) && inviter.slug.presence) || link.token
    cookies[:reference] = { value: ref.to_s.first(64), expires: 30.days, same_site: :lax }
    redirect_to(safe_path(link.target) || root_path, allow_other_host: false)
  end

  private

  def safe_path(path)
    p = path.to_s
    p.start_with?("/") && !p.start_with?("//") ? p : nil
  end
end
