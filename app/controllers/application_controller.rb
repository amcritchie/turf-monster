class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
  include GeoHelper

  allow_browser versions: :modern

  before_action :verify_session_token  # OPSEC-045
  before_action :set_current_context
  before_action :capture_reference
  before_action :detect_geo_state
  before_action :require_profile_completion
  helper_method :geo_state, :geo_blocked?, :geo_override_active?, :display_balance, :display_seeds_data, :onchain_session?, :wallet_context

  # OPSEC-045: extend the engine's set_app_session to also bind a per-user
  # session_token in the cookie. The verify_session_token before_action
  # compares the cookie token to user.session_token on every request —
  # mismatch → forced logout, which is how password rotation kicks out
  # stolen sessions.
  def set_app_session(user)
    super
    session[:session_token] = user.session_token
    # The onchain-session flag is a Phantom-wallet-signature privilege. Reset
    # it on every login so a stale flag from an earlier Phantom session can't
    # leak into a later email/Google login (which would make ContestsController
    # #enter demand a wallet signature). SolanaSessionsController#verify calls
    # set_app_session and then re-grants the flag for genuine wallet auth.
    session.delete(:onchain)
  end

  # Clear the onchain flag on logout too, alongside the engine's session wipe.
  def clear_app_session
    super
    session.delete(:onchain)
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

  # Canonical auth + wallet state for this request — the single source of truth
  # the whole UI branches on (web3 / web2 / guest). Serialised into the page and
  # mirrored client-side by Alpine.store('session'). See SessionContext.
  def wallet_context
    @wallet_context ||= SessionContext.new(user: current_user, onchain_session: onchain_session?)
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

  # Navbar balance — always on-chain USDC for connected wallets.
  # Memoized on the controller instance: the value can't change within a
  # single request, and views call this helper multiple times across the
  # navbar, layout, and action body. Without per-request memoization the
  # 60s Rails.cache.fetch — which is :null_store in dev — re-issues a
  # Solana RPC chain on every call site.
  #
  # Reuses @wallet_balances when the controller already populated it (e.g.
  # AccountsController#show via load_solana_balances). Avoids running
  # fetch_wallet_balances twice in the same request.
  def display_balance
    return @display_balance if defined?(@display_balance)

    @display_balance =
      if @wallet_balances.is_a?(Hash) && @wallet_balances.key?(:usdc)
        @wallet_balances[:usdc] || 0
      elsif current_user.solana_connected?
        begin
          Rails.cache.fetch(usdc_cache_key, expires_in: 60.seconds) { fetch_user_usdc }
        rescue => e
          Rails.logger.warn "Failed to fetch onchain balance: #{e.message}"
          0
        end
      else
        0
      end
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

  # Navbar seeds bar — on-chain seed count for the logged-in user.
  # Per-request memoized for the same reason as display_balance: the
  # navbar + seeds_bar partials both ask for this data, and the 60s
  # Rails.cache.fetch is a no-op under dev's :null_store store.
  #
  # Reuses @user_seeds when the controller already loaded it (e.g.
  # AccountsController#show via load_solana_balances), avoiding a second
  # sync_balance RPC.
  def display_seeds_data
    return @display_seeds_data if defined?(@display_seeds_data)

    @display_seeds_data =
      if defined?(@user_seeds) && !@user_seeds.nil?
        seeds_payload(@user_seeds)
      elsif current_user&.solana_connected?
        begin
          Rails.cache.fetch(seeds_cache_key, expires_in: 60.seconds) do
            onchain = Solana::Vault.new.sync_balance(current_user.solana_address)
            seeds_payload(onchain&.dig(:seeds) || 0)
          end
        rescue => e
          Rails.logger.warn "Failed to fetch onchain seeds: #{e.message}"
          seeds_payload(0)
        end
      else
        seeds_payload(0)
      end
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

  # B4 / OPSEC-048: block money-moving actions when the account is frozen
  # (chargeback / refund / dispute pending review). Read-only access stays open.
  def require_unfrozen_account
    return unless logged_in?
    return unless current_user.frozen?
    msg = "Your account is on hold pending review of a recent payment. Please contact support@turfmonster.media."
    respond_to do |format|
      format.html { redirect_to account_path, alert: msg }
      format.json { render json: { error: msg }, status: :forbidden }
    end
  end
end
