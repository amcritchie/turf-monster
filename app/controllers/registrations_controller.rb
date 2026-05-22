# Local override of the engine RegistrationsController. Identical to the engine
# version except new signups land on the entry-tokens page (the post-signup
# upsell) instead of the app root.
class RegistrationsController < ApplicationController
  skip_before_action :require_authentication

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    Studio.configure_new_user.call(@user)
    rescue_and_log(target: @user) do
      @user.save!
      set_app_session(@user)
      redirect_to tokens_buy_path, notice: Studio.welcome_message.call(@user)
    end
  rescue StandardError => e
    render :new, status: :unprocessable_entity
  end

  private

  def user_params
    params.require(:user).permit(*Studio.registration_params)
  end
end
