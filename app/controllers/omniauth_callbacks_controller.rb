class OmniauthCallbacksController < ApplicationController
  include UserMergeable

  skip_before_action :require_authentication
  before_action :capture_oauth_popup_flag, only: [:create, :failure]

  # Popup entrypoint — flags the session so the callback renders the
  # window-closer page instead of redirecting, then hands off to OmniAuth's
  # request phase. Reached via window.open from the Turf Totals auth modal.
  def popup
    session[:oauth_popup] = true
    redirect_to "/auth/google_oauth2"
  end

  # OPSEC-005: Google OAuth callbacks now run through GoogleOauthValidator
  # before we trust auth.info.email. The validator hits Google's tokeninfo
  # endpoint and re-confirms (a) audience matches our client ID, (b)
  # email_verified is true per Google, (c) the token isn't expired.
  # This closes the silent from_omniauth find-by-email link surface: an
  # unverified Google email can no longer be used to take over an existing
  # password-only account.
  def create
    auth = request.env["omniauth.auth"]

    # Defensive: a nil auth hash means OmniAuth never populated it (e.g.
    # test_mode with no mock configured, or a malformed callback). Fail
    # cleanly instead of NoMethodError on `auth.extra`.
    if auth.nil?
      Rails.logger.warn("[OmniauthCallbacks] missing omniauth.auth — failing gracefully")
      return finish_oauth((logged_in? ? account_path : signin_path), success: false,
                          alert: "Google sign-in failed. Please try again.")
    end

    # omniauth-google-oauth2 v1.x exposes the id_token under `extra`; older
    # versions put it in `credentials`. Reading the wrong key yields nil and
    # the validator rejects every sign-in with `missing_id_token`.
    validator_result = GoogleOauthValidator.new(id_token: auth.extra&.id_token).validate!
    unless validator_result.ok?
      Rails.logger.warn("[OmniauthCallbacks] rejected (#{validator_result.reason}) email=#{auth.info.email}")
      return finish_oauth((logged_in? ? account_path : signin_path), success: false,
                          alert: "Google sign-in rejected (#{validator_result.reason}). Make sure your Google email is verified.")
    end

    # Linking from /account while logged in
    if logged_in?
      existing = User.find_by(provider: auth.provider, uid: auth.uid)
      if existing && existing.id != current_user.id
        # OPSEC-005: don't silently merge. The previous behavior here was
        # merge_users!(survivor: current_user, absorbed: existing) — which
        # via the ID-swap inside merge_users! pivoted the session into the
        # older account. We now refuse and surface a sign-in CTA instead.
        rescue_and_log(target: current_user, parent: existing) do
          finish_oauth(account_path, success: false,
                       alert: "That Google account is linked to a different Turf Monster account. Sign in there directly, or unlink Google from this account first.")
        end
      else
        rescue_and_log(target: current_user) do
          current_user.update!(
            provider: auth.provider,
            uid: auth.uid,
            email_verified_at: current_user.email_verified_at || Time.current
          )
          finish_oauth(account_path, success: true,
                       needs_profile: !current_user.profile_complete?,
                       notice: "Google account linked.")
        end
      end
    else
      # Normal login/signup flow. Capture "is this a brand-new account?"
      # before from_omniauth — the User after_create runs its own update!
      # (managed wallet), so previously_new_record? is unreliable afterward.
      new_signup = User.find_by(provider: auth.provider, uid: auth.uid).nil? &&
                   User.find_by(email: auth.info.email).nil?
      result = User.from_omniauth(auth, email_verified: true)
      case result
      when :email_not_verified
        return finish_oauth(signin_path, success: false,
                            alert: "Google sign-in rejected: your email is not verified by Google.")
      when :requires_verification
        existing = User.find_by(email: auth.info.email)
        # A wallet-secured account can't prove email ownership via password —
        # route the user to a wallet login that completes the Google link once
        # they sign. The Google identity is already GoogleOauthValidator-checked
        # above, so stashing it for the post-wallet-login step is safe.
        if existing&.phantom_wallet?
          session[:pending_google_link] = {
            "user_id"  => existing.id,
            "provider" => auth.provider,
            "uid"      => auth.uid,
            "email"    => auth.info.email,
            "at"       => Time.current.to_i
          }
          if @oauth_popup
            return finish_oauth(signin_path, success: false,
                                alert: "#{auth.info.email} is a wallet account — log in with your Solana wallet to link Google.")
          end
          return redirect_to link_wallet_path
        end
        return finish_oauth(signin_path, success: false,
                            alert: "An account already exists for #{auth.info.email}. Sign in with your password and verify your email before linking Google.")
      end

      # First-touch funnel attribution for brand-new Google signups.
      if new_signup && result.is_a?(User) && result.reference.blank? && cookies[:reference].present?
        result.update_column(:reference, cookies[:reference].to_s.first(64))
        cookies.delete(:reference)
      end

      rescue_and_log(target: result) do
        set_app_session(result)
        # New signups land on the entry-tokens page (post-signup upsell);
        # returning Google users go to the app root.
        finish_oauth(new_signup ? tokens_buy_path : root_path, success: true,
                     needs_profile: !result.profile_complete?,
                     notice: "Signed in with Google!")
      end
    end
  rescue StandardError => e
    Rails.logger.error("[OmniauthCallbacks] #{e.class}: #{e.message}")
    finish_oauth((logged_in? ? account_path : signin_path), success: false,
                 alert: "Google sign-in failed. Please try again.")
  end

  def failure
    finish_oauth(signin_path, success: false, alert: "Google sign-in failed. Please try again.")
  end

  private

  # Capture (and clear) the popup-mode flag set by #popup. One-shot.
  def capture_oauth_popup_flag
    @oauth_popup = session.delete(:oauth_popup) == true
  end

  # Finish the OAuth callback. In popup mode, render a window-closer page that
  # postMessages the result to the opener and self-closes; otherwise a normal
  # flash + redirect. `success` / `needs_profile` shape the popup payload.
  def finish_oauth(path, success:, needs_profile: false, alert: nil, notice: nil)
    if @oauth_popup
      @oauth_payload = if success
        { status: "success", needs_profile_completion: needs_profile }
      else
        { status: "error", error: alert || "Google sign-in failed." }
      end
      return render "popup_close", layout: false
    end

    opts = {}
    opts[:alert]  = alert  if alert
    opts[:notice] = notice if notice
    redirect_to path, **opts
  end
end
