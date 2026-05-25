# Test-only endpoints used by Playwright specs. Routes are guarded in
# config/routes.rb with `if Rails.env.test?` so this controller is
# unreachable in dev/staging/production.
class TestController < ApplicationController
  skip_before_action :require_authentication
  skip_before_action :verify_authenticity_token

  # Set the OmniAuth mock_auth payload for the next /auth/:provider call.
  # Playwright posts to this immediately before navigating to /auth/google_oauth2
  # so the e2e spec controls who "signs in" with Google.
  def set_oauth_mock
    provider = params[:provider].presence || "google_oauth2"
    OmniAuth.config.mock_auth[provider.to_sym] = OmniAuth::AuthHash.new(
      provider: provider,
      uid:      params[:uid].to_s,
      info: {
        email: params[:email].to_s,
        name:  params[:name].to_s
      }
    )
    render json: { ok: true }
  end

  # Force a user's referral cache counters to a specific value so the
  # Playwright account-UI tests can exercise the "1 of 2 friends" and
  # "ENTRY TOKEN COMING SOON" states without staging full signup flows.
  def set_user_referral_counts
    user = User.find_by!(slug: params[:slug])
    user.update_columns(
      invitees_count:            params[:invitees_count].to_i,
      invitees_in_contest_count: params[:invitees_in_contest_count].to_i
    )
    render json: { ok: true, user: user.slug,
                   ic:  user.invitees_count,
                   iic: user.invitees_in_contest_count }
  end

  # Create an :active Entry for the current session's user in a given
  # contest. Triggers Entry#after_commit → ReferralProgress.mark_entered!
  # naturally — same callback path the real /enter action would hit, but
  # without the on-chain Vault dance that needs devnet connectivity.
  # Returns the user's + inviter's slugs so the spec can verify state.
  def create_active_entry
    return render json: { error: "not logged in" }, status: :unauthorized unless current_user

    contest = Contest.find_by!(slug: params[:contest_slug])
    Entry.create!(user: current_user, contest: contest, status: :active)

    render json: {
      ok: true,
      user_slug:    current_user.slug,
      inviter_slug: current_user.inviter&.slug
    }
  end

  # Read-only JSON view of a user's referral state so specs can assert
  # without scraping HTML. Looks up by slug (path param).
  def user_info
    user = User.find_by!(slug: params[:slug])
    render json: {
      slug:                      user.slug,
      username:                  user.username,
      email:                     user.email,
      contest_entered:           user.contest_entered?,
      invitees_count:            user.invitees_count,
      invitees_in_contest_count: user.invitees_in_contest_count,
      inviter_slug:              user.inviter&.slug
    }
  end
end
