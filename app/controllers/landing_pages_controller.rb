class LandingPagesController < ApplicationController
  skip_before_action :require_authentication
  skip_before_action :require_profile_completion, raise: false

  layout "landing"

  def show
    @landing_page = LandingPage.find_by(slug: params[:slug])

    # Inactive pages are visible to admins only (for preview before launch).
    if @landing_page.nil? || (!@landing_page.active? && !current_user&.admin?)
      return redirect_to root_path, alert: "That landing page isn't available."
    end

    # First-touch attribution: tag the visitor with this funnel's slug so it
    # lands on the user at signup. An explicit ?reference= (captured by
    # ApplicationController#capture_reference) already in the cookie wins.
    cookies[:reference] = { value: @landing_page.slug, expires: 30.days } if cookies[:reference].blank?

    @contest = @landing_page.contest
  end
end
