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
      # OPSEC-046: email changes are a re-auth event. Require the current
      # password (or proof of an unverified pre-change state, see below)
      # before accepting. Also reset email_verified_at so the new address
      # must be re-verified, and notify the OLD address as an out-of-band
      # alert in case the change wasn't initiated by the legit user.
      new_params = account_params
      email_changing = new_params[:email].present? && new_params[:email].to_s.downcase != @user.email.to_s.downcase
      old_email = @user.email

      if email_changing
        if @user.has_password? && !@user.authenticate(params[:current_password].to_s)
          flash.now[:alert] = "Confirm your current password to change email."
          render :show, status: :unprocessable_entity and return
        end
        new_params = new_params.merge(email_verified_at: nil)
      end

      @user.update!(new_params)

      if email_changing && old_email.present?
        UserMailer.email_change_notification(@user, old_email, @user.email).deliver_later
      end

      redirect_to account_path, notice: email_changing ? "Account updated. Verify your new email — link sent to #{@user.email}." : "Account updated."
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
      session: session,
      expected_user_id: current_user.id  # OPSEC-005: session-bind the signature
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

  # OPSEC-007: removed `update_level` action. Previously accepted client-supplied
  # `seeds_total` and persisted level from it — trivial to inflate via curl. The
  # navbar already reads on-chain seeds via `seedsNavbar` localStorage written
  # by `confirm_onchain_entry`'s response (authoritative server figure). The
  # cached `users.level` column is now best-effort display only; recompute
  # server-side from `Solana::Vault#sync_balance` when truly needed.

  def change_password
    rescue_and_log(target: current_user) do
      # If user already has a password, verify current one
      if current_user.has_password? && !current_user.authenticate(params[:current_password])
        flash.now[:alert] = "Current password is incorrect."
        @user = current_user
        return render :show, status: :unprocessable_entity
      end

      current_user.update!(password: params[:new_password], password_confirmation: params[:new_password_confirmation])

      # OPSEC-045: rotate the session token so any OTHER live session
      # (stolen cookie on a different device) loses access. Update THIS
      # session's cookie to the new token so the legit user stays signed in.
      new_token = current_user.regenerate_session_token!
      session[:session_token] = new_token

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
