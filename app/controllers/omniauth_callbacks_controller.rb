class OmniauthCallbacksController < ApplicationController
  include UserMergeable

  skip_before_action :require_authentication

  # OPSEC-005: Google OAuth callbacks now run through GoogleOauthValidator
  # before we trust auth.info.email. The validator hits Google's tokeninfo
  # endpoint and re-confirms (a) audience matches our client ID, (b)
  # email_verified is true per Google, (c) the token isn't expired.
  # This closes the silent from_omniauth find-by-email link surface: an
  # unverified Google email can no longer be used to take over an existing
  # password-only account.
  def create
    auth = request.env["omniauth.auth"]

    validator_result = GoogleOauthValidator.new(id_token: auth.credentials&.id_token).validate!
    unless validator_result.ok?
      Rails.logger.warn("[OmniauthCallbacks] rejected (#{validator_result.reason}) email=#{auth.info.email}")
      return redirect_to (logged_in? ? account_path : login_path),
                        alert: "Google sign-in rejected (#{validator_result.reason}). Make sure your Google email is verified."
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
          redirect_to account_path, alert: "That Google account is linked to a different Turf Monster account. Sign in there directly, or unlink Google from this account first."
        end
      else
        rescue_and_log(target: current_user) do
          current_user.update!(
            provider: auth.provider,
            uid: auth.uid,
            email_verified_at: current_user.email_verified_at || Time.current
          )
          redirect_to account_path, notice: "Google account linked."
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
        return redirect_to login_path, alert: "Google sign-in rejected: your email is not verified by Google."
      when :requires_verification
        return redirect_to login_path, alert: "An account already exists for #{auth.info.email}. Sign in with your password and verify your email before linking Google."
      end

      # First-touch funnel attribution for brand-new Google signups.
      if new_signup && result.is_a?(User) && result.reference.blank? && cookies[:reference].present?
        result.update_column(:reference, cookies[:reference].to_s.first(64))
        cookies.delete(:reference)
      end

      rescue_and_log(target: result) do
        set_app_session(result)
        redirect_to root_path, notice: "Signed in with Google!"
      end
    end
  rescue StandardError => e
    Rails.logger.error("[OmniauthCallbacks] #{e.class}: #{e.message}")
    redirect_to (logged_in? ? account_path : login_path), alert: "Google sign-in failed. Please try again."
  end

  def failure
    redirect_to login_path, alert: "Google sign-in failed. Please try again."
  end
end
