class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
  include GeoHelper

  allow_browser versions: :modern

  before_action :set_current_context
  before_action :detect_geo_state
  before_action :require_profile_completion
  helper_method :geo_state, :geo_blocked?, :geo_override_active?, :display_balance, :display_seeds_data, :onchain_session?

  private

  # Populates Current.* for the request lifecycle so OutboundRequestLogger can
  # attribute Stripe / Solana calls back to the user without param threading.
  def set_current_context
    Current.user = current_user if logged_in?
  rescue
    nil # context is best-effort; never break the request path
  end

  # True when the current session was authenticated via Solana wallet signature
  # (not email/password). Set by SolanaSessionsController#verify.
  def onchain_session?
    session[:onchain] == true
  end

  def detect_geo_state
    return if session[:geo_override].present?

    ip_changed = session[:geo_ip] != request.remote_ip
    stale = session[:geo_detected_at].blank? || session[:geo_detected_at] < 24.hours.ago.to_s

    if ip_changed || stale
      result = Geocoder.search(request.remote_ip).first
      raw = result&.try(:state_code).presence || result&.try(:region_code) || result&.try(:region)
      session[:geo_state] = normalize_state_code(raw)
      session[:geo_ip] = request.remote_ip
      session[:geo_detected_at] = Time.current.to_s
    end
  rescue => e
    Rails.logger.warn "Geo detection failed: #{e.message}"
    session[:geo_detected_at] = Time.current.to_s
  end

  def geo_state
    normalize_state_code(session[:geo_override] || session[:geo_state])
  end

  def geo_blocked?
    GeoSetting.blocked?(geo_state)
  end

  def geo_override_active?
    session[:geo_override].present?
  end

  # Navbar balance — always on-chain USDC for connected wallets
  def display_balance
    return 0 unless current_user.solana_connected?

    Rails.cache.fetch(usdc_cache_key, expires_in: 60.seconds) do
      fetch_user_usdc
    end
  rescue => e
    Rails.logger.warn "Failed to fetch onchain balance: #{e.message}"
    0
  end

  # Fresh onchain USDC balance from logged-in user's wallet
  def fetch_user_usdc
    vault = Solana::Vault.new
    balances = vault.fetch_wallet_balances(current_user.solana_address)
    balances[:usdc] || 0
  end

  def usdc_cache_key(user = current_user)
    "usdc_balance:#{user.id}"
  end

  def invalidate_usdc_cache(user = current_user)
    Rails.cache.delete(usdc_cache_key(user))
  end

  # Navbar seeds bar — on-chain seed count for the logged-in user
  def display_seeds_data
    return seeds_payload(0) unless current_user&.solana_connected?

    Rails.cache.fetch(seeds_cache_key, expires_in: 60.seconds) do
      onchain = Solana::Vault.new.sync_balance(current_user.solana_address)
      seeds_payload(onchain&.dig(:seeds) || 0)
    end
  rescue => e
    Rails.logger.warn "Failed to fetch onchain seeds: #{e.message}"
    seeds_payload(0)
  end

  def seeds_payload(seeds)
    {
      seeds: seeds,
      level: User.level_for(seeds),
      toward_next: User.seeds_toward_next_level(seeds),
      progress: User.seeds_progress_percent(seeds),
      seeds_to_next: User::SEEDS_PER_LEVEL - User.seeds_toward_next_level(seeds)
    }
  end

  def seeds_cache_key(user = current_user)
    "user_seeds:#{user.id}"
  end

  def invalidate_seeds_cache(user = current_user)
    Rails.cache.delete(seeds_cache_key(user))
  end

  def require_profile_completion
    return unless logged_in?
    return if current_user.profile_complete?
    return if self.class.name.in?(%w[SessionsController RegistrationsController SolanaSessionsController FaucetController])
    return if controller_name == "accounts"

    session[:return_to] = request.fullpath
    redirect_to complete_profile_account_path
  end

  def require_geo_allowed
    if geo_blocked?
      respond_to do |format|
        format.html { redirect_to root_path, alert: "This feature is not available in your state (#{geo_state})." }
        format.json { render json: { error: "Restricted in #{geo_state}" }, status: :forbidden }
      end
    end
  end
end
