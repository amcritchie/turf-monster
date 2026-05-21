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
      render json: { success: true, user: { id: @user.id, name: @user.display_name } }
    else
      render json: { success: false, error: @user.errors.full_messages.first || "Could not create account." },
             status: :unprocessable_entity
    end
  end
end
