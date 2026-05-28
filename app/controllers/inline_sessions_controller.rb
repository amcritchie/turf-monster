class InlineSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    user = User.find_by(email: params[:email])
    if user&.authenticate(params[:password])
      set_app_session(user)
      session[:password_verified_at] = Time.current.to_i
      render json: {
        success: true,
        user: { id: user.id, name: user.display_name, has_wallet: user.web3_solana_address.present? }
      }
    else
      render json: { success: false, error: "Invalid email or password." }, status: :unauthorized
    end
  end
end
