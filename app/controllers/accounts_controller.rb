class AccountsController < ApplicationController
  include UserMergeable
  include Solana::SessionAuth

  skip_before_action :require_profile_completion, only: [:show, :complete_profile, :save_profile]

  def show
    @user = current_user
    load_solana_balances if @user.solana_connected?
  end

  def complete_profile
    @user = current_user
  end

  def save_profile
    @user = current_user
    rescue_and_log(target: @user) do
      @user.update!(profile_params)

      # First-time username sets up an entry-tokens upsell.
      # An explicit return_to (e.g. mid-checkout) still wins.
      first_username = @user.saved_change_to_username&.first.nil?
      target = session.delete(:return_to)
      target ||= first_username ? tokens_buy_path : root_path

      respond_to do |format|
        format.html { redirect_to target, notice: "Profile updated!" }
        format.json { render json: { success: true, display_name: @user.display_name, redirect: target } }
      end
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { flash.now[:alert] = e.message; render :complete_profile, status: :unprocessable_entity }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def update
    @user = current_user
    rescue_and_log(target: @user) do
      @user.update!(account_params)
      redirect_to account_path, notice: "Account updated."
    end
  rescue StandardError => e
    flash.now[:alert] = "Failed to update account."
    render :show, status: :unprocessable_entity
  end

  def link_solana
    pubkey_b58 = verify_solana_signature!(
      message: params[:message],
      signature_b58: params[:signature],
      pubkey_b58: params[:pubkey],
      session: session
    )

    rescue_and_log(target: current_user) do
      # Check if Solana wallet belongs to another user
      existing = User.from_solana_wallet(pubkey_b58)
      if existing && existing.id != current_user.id
        merge_users!(survivor: current_user, absorbed: existing)
        return render json: { success: true, redirect: account_path, notice: "Accounts merged." }
      end

      current_user.update!(web3_solana_address: pubkey_b58)
      render json: { success: true, redirect: account_path }
    end
  rescue Solana::AuthVerifier::VerificationError => e
    render json: { error: e.message }, status: :unauthorized
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def unlink_google
    rescue_and_log(target: current_user) do
      current_user.update!(provider: nil, uid: nil)
      redirect_to account_path, notice: "Google account unlinked."
    end
  rescue StandardError => e
    redirect_to account_path, alert: "Failed to unlink Google."
  end

  def set_inviter
    return render json: { ok: true } if current_user.invited_by_id.present?

    inviter = User.find_by(slug: params[:inviter_slug])
    return render json: { error: "not found" }, status: :not_found unless inviter
    return render json: { error: "self" }, status: :unprocessable_entity if inviter.id == current_user.id

    rescue_and_log(target: current_user) do
      current_user.update!(invited_by_id: inviter.id)
      render json: { ok: true }
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update_level
    seeds_total = params[:seeds_total].to_i

    rescue_and_log(target: current_user) do
      current_user.update_level_from_seeds!(seeds_total)
      render json: { success: true, level: current_user.level }
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def change_password
    rescue_and_log(target: current_user) do
      # If user already has a password, verify current one
      if current_user.has_password? && !current_user.authenticate(params[:current_password])
        flash.now[:alert] = "Current password is incorrect."
        @user = current_user
        return render :show, status: :unprocessable_entity
      end

      current_user.update!(password: params[:new_password], password_confirmation: params[:new_password_confirmation])
      redirect_to account_path, notice: "Password updated."
    end
  rescue StandardError => e
    flash.now[:alert] = e.message
    @user = current_user
    render :show, status: :unprocessable_entity
  end

  private

  def account_params
    params.require(:user).permit(:name, :email, :avatar)
  end

  def profile_params
    params.require(:user).permit(:username, :avatar)
  end

  def load_solana_balances
    vault = Solana::Vault.new
    @wallet_balances = vault.fetch_wallet_balances(@user.solana_address)
  rescue StandardError
    @wallet_balances = nil
  end
end
