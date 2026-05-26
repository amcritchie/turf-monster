class AccountsController < ApplicationController
  include UserMergeable
  include Solana::SessionAuth

  # session_state is callable by guests on purpose — if a tab's session
  # expired server-side, the client-side rehydrate (visibilitychange /
  # cross-tab broadcast) needs to GET the guest shape back to flip the
  # store. Otherwise auth-required would 302 → /login and the JS can't
  # parse the response.
  skip_before_action :require_authentication, only: [:session_state]
  skip_before_action :require_profile_completion, only: [:show, :complete_profile, :save_profile, :session_state]

  def show
    @user = current_user
    # All on-chain data (@wallet_balances, @user_seeds, the User's
    # @entry_token_balance memo, Current.vault_state) is prefetched by
    # ApplicationController#preload_navbar_solana_data — no per-action fetch
    # needed here.
    #
    # Referral widget — share URL points at the canonical main contest
    # (admin-set via /admin/site_config). SeasonConfig.main_contest masks
    # the explicit pick when it's settled/locked and falls back to the
    # most recent open contest; nil if nothing is open at all (the widget
    # then degrades to a root-path share URL).
    @referral_share_contest = SeasonConfig.main_contest
  end

  # Fresh on-chain state (USDC, free-entry tokens, seeds + level) in a
  # single JSON payload. The client-side refreshSession() helper calls
  # this after every on-chain success (entry confirm, token mint, token
  # consume, withdrawal, etc.) so the navbar balance, token badge, and
  # seeds bar can all converge to truth from one place — instead of each
  # success path having to know about three separate update mechanisms.
  #
  # Uses perform_solana_preload so the four reads (wallet balances, user
  # account, entry tokens, vault state) run in parallel. Returns the
  # current values whether the user has a connected wallet or not.
  def session_refresh
    perform_solana_preload if current_user&.solana_connected?

    seeds = @user_seeds.to_i
    render json: {
      usdc:        @wallet_balances&.dig(:usdc) || 0,
      sol:         @wallet_balances&.dig(:sol)  || 0,
      tokens:      (current_user&.entry_token_balance rescue 0),
      seeds:       seeds,
      level:       User.level_for(seeds),
      toward_next: User.seeds_toward_next_level(seeds),
      progress:    User.seeds_progress_percent(seeds)
    }
  end

  # Lightweight session-state probe for client-side rehydration. Returns the
  # canonical wallet_context plus a fresh CSRF token so a tab returning from
  # background can detect server-side logout (verify_session_token gives 401)
  # OR get the current truth (this action returns guest/web2/web3 state) and
  # rotate its CSRF for the next POST. No DB writes; cheap to call.
  def session_state
    render json: wallet_context.to_h.merge(csrf: form_authenticity_token)
  end

  def complete_profile
    @user = current_user
  end

  def save_profile
    @user = current_user
    rescue_and_log(target: @user) do
      @user.update!(profile_params)

      # Usernames are auto-assigned at signup — this form just saves the avatar.
      target = session.delete(:return_to) || root_path

      respond_to do |format|
        format.html { redirect_to target, notice: "Profile updated!" }
        format.json { render json: { success: true, display_name: @user.display_name, redirect: target } }
      end
    end
  rescue StandardError
    title, message = profile_error_toast
    respond_to do |format|
      format.html do
        @profile_error_title = title
        @profile_error_message = message
        render :complete_profile, status: :unprocessable_entity
      end
      format.json { render json: { error: message }, status: :unprocessable_entity }
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

  # On-chain username edit. Custodial (managed) wallets: the server co-signs
  # set_username immediately. Phantom wallets: returns a partial TX for the
  # wallet to co-sign, confirmed via #confirm_username.
  def update_username
    @user = current_user
    new_username = params[:username].to_s.strip
    @user.username = new_username

    # Server-side mirror of the UI gate (modals/_username.html.erb +
    # User#can_change_username?). Belt-and-suspenders so a direct POST
    # can't bypass the "enter a contest first" lock.
    unless @user.can_change_username?
      reason = @user.solana_connected? ? "Enter a contest first to unlock username changes." : "No wallet on this account."
      return render json: { success: false, error: reason }, status: :forbidden
    end

    unless @user.valid?
      return render json: { success: false, error: @user.errors.full_messages.first }, status: :unprocessable_entity
    end

    if @user.phantom_wallet?
      # Phantom: hand the client a partial set_username TX to co-sign.
      result = Solana::Vault.new.build_set_username(@user.solana_address, new_username)
      render json: {
        needs_signature: true,
        serialized_tx: result[:serialized_tx],
        token: sign_username_payload(new_username)
      }
    else
      # Custodial: the server co-signs with the managed keypair, then mirrors to the DB.
      rescue_and_log(target: @user) do
        Solana::Vault.new.set_username(@user.solana_address, new_username, user_keypair: @user.solana_keypair)
        @user.save!
        render json: { success: true, username: @user.username }
      end
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # Phantom username edit, step 2: the wallet co-signed + broadcast the
  # set_username TX; verify it on-chain (OPSEC-010), then mirror to the DB.
  def confirm_username
    @user = current_user
    payload = verify_username_payload(params[:token])
    raise "Token issued for a different account" unless payload[:user_id] == @user.id
    new_username = payload[:username]

    user_pda_b58 = Solana::Keypair.encode_base58(
      Solana::Vault.new.user_account_pda(@user.solana_address).first
    )
    Solana::TxVerifier.verify!(
      signature: params[:tx_signature],
      instruction_name: "set_username",
      signer_pubkey: @user.solana_address,
      writable_pubkey: user_pda_b58
    )

    rescue_and_log(target: @user) do
      @user.update!(username: new_username)
      render json: { success: true, username: @user.username }
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render json: { success: false, error: "Rename expired — please try again." }, status: :unprocessable_entity
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def account_params
    params.require(:user).permit(:name, :email, :avatar)
  end

  def profile_params
    params.require(:user).permit(:avatar)
  end

  # Signed round-trip token so the username can't be swapped between the
  # prepare (#update_username) and confirm (#confirm_username) steps.
  def sign_username_payload(username)
    Rails.application.message_verifier(:account_username_change)
         .generate({ user_id: current_user.id, username: username }, expires_in: 10.minutes)
  end

  def verify_username_payload(token)
    Rails.application.message_verifier(:account_username_change)
         .verify(token).with_indifferent_access
  end

  # Friendly (title, message) for a profile-save failure. A username
  # collision is a normal user error, so it gets a specific, non-scary toast
  # rather than the raw "Validation failed: …" exception message.
  def profile_error_toast
    username_taken = @user.errors.details[:username]&.any? { |d| d[:error] == :taken }
    if username_taken
      ["Username Taken", "Please choose a new username"]
    else
      ["Couldn't Save Profile", @user.errors.full_messages.first || "Please try again."]
    end
  end

end
