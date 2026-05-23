# Inline (modal) email + password signup — JSON only. Mirrors
# InlineSessionsController but creates the account first. Used by the Turf
# Totals board "Create Your Account" modal so a guest can sign up without
# leaving the contest page; the caller then resumes the saved cart.
class InlineRegistrationsController < ApplicationController
  skip_before_action :require_authentication

  def create
    attrs = { email: params[:email], password: params[:password] }
    attrs[:reference] = cookies[:reference] if cookies[:reference].present?
    @user = User.new(attrs)
    Studio.configure_new_user.call(@user)

    created = false
    rescue_and_log(target: @user) { created = @user.save }

    if created
      set_app_session(@user)
      # set_app_session writes to session[] but doesn't reset the memoized
      # @current_user — assign it explicitly so the navbar partial + the
      # SessionContext below see the just-created user.
      @current_user = @user
      @wallet_context = nil  # invalidate the memoized guest-mode context

      render json: {
        success: true,
        user:    { id: @user.id, name: @user.display_name },
        session: wallet_context.to_h,
        # Server-rendered navbar in its new authed state — the client
        # outerHTML-swaps the existing <header data-navbar-root> so we get
        # the logged-in chrome (username, balance, seeds bar) without a
        # full-page reload. formats: [:html] is required — the request is
        # JSON, so without it Rails looks for _navbar.json.erb and 500s.
        navbar_html: render_to_string(partial: "layouts/navbar", formats: [:html])
      }
    else
      render json: { success: false, error: @user.errors.full_messages.first || "Could not create account." },
             status: :unprocessable_entity
    end
  end
end
