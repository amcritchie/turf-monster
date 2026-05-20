class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
  include GeoHelper

  allow_browser versions: :modern

  before_action :verify_session_token  # OPSEC-045
  before_action :set_current_context
  before_action :capture_reference
  before_action :detect_geo_state
  before_action :require_profile_completion
  helper_method :geo_state, :geo_blocked?, :geo_override_active?, :display_balance, :display_seeds_data, :onchain_session?

  # OPSEC-045: extend the engine's set_app_session to also bind a per-user
  # session_token in the cookie. The verify_session_token before_action
  # compares the cookie token to user.session_token on every request —
  # mismatch → forced logout, which is how password rotation kicks out
  # stolen sessions.
  def set_app_session(user)
    super
    session[:session_token] = user.session_token
  end

  private

  # Populates Current.* for the request lifecycle so OutboundRequestLogger can
  # attribute Stripe / Solana calls back to the user without param threading.
  def set_current_context
    Current.user = current_user if logged_in?
  rescue
    nil # context is best-effort; never break the request path
  end

  # Funnel/campaign attribution. Captures a `?reference=` URL param into a
  # cookie on first touch (never overwritten) so it survives the journey to
  # signup, where it's written onto the new user across all auth paths.
  # Landing pages also seed this cookie with their slug — see
  # LandingPagesController#show.
  def capture_reference
    return if params[:reference].blank?
    return if cookies[:reference].present?

    cookies[:reference] = { value: params[:reference].to_s.first(64), expires: 30.days }
  end

  # OPSEC-045: enforces session-token binding. Runs early so a stale session
  # gets cleared before any downstream code reads current_user.
  def verify_session_token
    return unless logged_in?
    user_token   = current_user.session_token
    cookie_token = session[:session_token]

    return if user_token.present? && user_token == cookie_token

    Rails.logger.info("[opsec-045] session_token mismatch user_id=#{current_user.id} — forcing re-login")
    @current_user = nil
    clear_app_session
    respond_to do |format|
      format.html { redirect_to login_path, alert: "Your session expired. Please sign in again." }
      format.json { render json: { error: "session expired" }, status: :unauthorized }
    end
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
