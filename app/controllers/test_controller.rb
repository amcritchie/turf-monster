# Test-only endpoints used by Playwright specs. Routes are guarded in
# config/routes.rb with `unless Rails.env.production?` so this controller is
# reachable in dev (Playwright's default boot) but unreachable in production.
class TestController < ApplicationController
  skip_before_action :require_authentication
  skip_before_action :verify_authenticity_token

  # Fast inter-spec reset. Playwright spec files call this in test.beforeAll
  # to drop the most common cross-spec pollution sources without re-running
  # the full e2e/seed.rb. Specifically:
  #
  #   - rack-attack throttle counters: a previous spec's repeated logins
  #     push `login/email` over its 5/min limit; the next spec's
  #     loginAdmin then hangs at form-submit and times out.
  #   - Entry-token Rails.cache (entry_tokens/v1/...): a stale post-mint
  #     cache lingers ~60s and the next spec reads "0 available" even
  #     after the chain shows a token.
  #   - OmniAuth.config.mock_auth: stale provider hashes from
  #     set_oauth_mock leak into the next spec and sign in the wrong user.
  #
  # Returns counts so flake hunts can grep the spec output.
  def reseed
    cleared = []

    # Rails.cache.delete_matched under the Redis cache store returns the
    # underlying Redis client array (circular ref) — don't render its return
    # value or to_json recurses to SystemStackError. We discard the return
    # and just note that we ran the call.
    #
    # rack-attack writes throttle counters under `rack::attack:<epoch>:<name>:<discriminator>`
    # (DOUBLE colon) — NOT `rack-attack:*`. Get the pattern wrong and the
    # counters survive the reseed and the next spec's login times out.
    begin
      Rails.cache.delete_matched("rack::attack:*")
      cleared << "rack::attack"
    rescue => e
      Rails.logger.warn "[reseed] delete_matched rack::attack:* failed: #{e.message}"
    end

    begin
      Rails.cache.delete_matched("entry_tokens/v1/*")
      cleared << "entry_tokens"
    rescue => e
      Rails.logger.warn "[reseed] delete_matched entry_tokens/v1/* failed: #{e.message}"
    end

    if defined?(OmniAuth) && OmniAuth.config.respond_to?(:mock_auth)
      OmniAuth.config.mock_auth.clear
      cleared << "omniauth_mocks"
    end

    # Wipe non-core users (id > 5) that linger from prior signup-flow tests.
    # Without this, referrals.spec.js's second run finds the existing
    # Phantom/Google/email-signup user with invited_by_id already set;
    # set_inviter doesn't re-fire; inviter counters stay at 0; assertions
    # fail. Core users (alex/alex-bot/mason/mack/turf at IDs 1-5) stay —
    # specs depend on their slugs being stable.
    #
    # destroy_all (not delete_all) so dependent: :destroy on User cascades
    # to entries, transaction_logs, stripe_purchases.
    begin
      victims = User.where("id > ?", 5)
      count = victims.count
      if count > 0
        victims.destroy_all
        cleared << "non_core_users(#{count})"
      end
    rescue => e
      Rails.logger.warn "[reseed] non-core user cleanup failed: #{e.class}: #{e.message[0,160]}"
    end

    render json: { ok: true, cleared: cleared }
  end

  # Phantom-mock admin handoff. The Playwright Phantom mock signs with
  # MOCK_PUBKEY_B58 (e2e/phantom-mock.js: 6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt);
  # the canonical alex user's wallet is the operator's real Phantom
  # (7ZDJp7FU…) so manual browser auth resolves to alex. To keep both
  # flows working from the same dev DB:
  #
  #   - `use_phantom_mock_admin` — called from Playwright globalSetup.
  #     Stashes alex's current wallet into a Rails.cache key, then points
  #     alex at MOCK_PUBKEY so loginViaPhantom resolves to alex.
  #   - `restore_canonical_admin` — called from Playwright globalTeardown.
  #     Reads the stashed wallet back. If the cache key is missing
  #     (crash, container restart, expired), falls back to
  #     ENV["ADMIN_CANONICAL_WALLET"] or the hard-coded operator wallet.
  PHANTOM_MOCK_WALLET      = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt".freeze
  ADMIN_WALLET_STASH_KEY   = "test/canonical_admin_wallet".freeze
  CANONICAL_ADMIN_FALLBACK = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze

  def use_phantom_mock_admin
    alex = User.find_by!(username: "alex")
    Rails.cache.write(ADMIN_WALLET_STASH_KEY, alex.web3_solana_address, expires_in: 1.hour)
    alex.update!(web3_solana_address: PHANTOM_MOCK_WALLET)
    render json: { ok: true, from: Rails.cache.read(ADMIN_WALLET_STASH_KEY), to: PHANTOM_MOCK_WALLET }
  end

  def restore_canonical_admin
    alex = User.find_by!(username: "alex")
    stashed = Rails.cache.read(ADMIN_WALLET_STASH_KEY)
    Rails.cache.delete(ADMIN_WALLET_STASH_KEY)
    canonical = stashed.presence ||
      ENV["ADMIN_CANONICAL_WALLET"].presence ||
      CANONICAL_ADMIN_FALLBACK
    alex.update!(web3_solana_address: canonical)
    render json: { ok: true, to: canonical, source: (stashed ? "stash" : "fallback") }
  end

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
