# Pre-launch audit C3 (2026-05-24): cross-app SSO from McRitchie Studio is
# disabled in turf-monster. Cookie isolation (config/initializers/session_store.rb)
# already prevents the hub's session fields from being readable here, so
# `sso_continue` / `sso_login` would no-op anyway — but we 404 them explicitly
# for defense-in-depth. Non-SSO actions (`new` / `create` / `destroy`) mirror
# studio-engine's SessionsController. Restoring SSO means deleting this file +
# reverting session_store.rb + sessions/new.html.erb. See docs/AUTH.md.
class SessionsController < ApplicationController
  skip_before_action :require_authentication

  def new
  end

  def create
    user = User.find_by(email: params[:email])
    if user&.authenticate(params[:password])
      set_app_session(user)
      # Stamp the moment of password proof. Sensitive actions (wallet export,
      # other future destructive-and-irreversible flows) require this stamp
      # to be recent. See ApplicationController#password_recently_verified?.
      session[:password_verified_at] = Time.current.to_i
      redirect_to root_path, notice: "Welcome back, #{user.display_name}!"
    else
      flash.now[:alert] = "Invalid email or password."
      render :new, status: :unprocessable_entity
    end
  end

  def sso_login
    head :not_found
  end

  def sso_continue
    head :not_found
  end

  def destroy
    clear_app_session
    # clear_app_session (engine) deletes the user session key + sso_* fields
    # but doesn't know about turf-monster's additional per-session state.
    # Drop everything user-bound so a subsequent login in the same browser
    # can't inherit stale phantom-auth flags, session-token bindings, or
    # auth nonces from the prior user.
    session.delete(:onchain)         # set by SolanaSessionsController#verify
    session.delete(:session_token)   # OPSEC-045
    session.delete(:solana_nonce)    # delete-before-verify replay guard
    session.delete(:solana_nonce_at)
    session.delete(:return_to)       # require_profile_completion redirect target
    redirect_to login_path, notice: "Logged out."
  end
end
