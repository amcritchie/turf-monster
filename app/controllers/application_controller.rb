class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
  include GeoHelper

  allow_browser versions: :modern

  before_action :verify_session_token  # OPSEC-045
  before_action :set_current_context
  before_action :capture_reference
  before_action :detect_geo_state
  before_action :require_profile_completion
  before_action :preload_navbar_solana_data
  helper_method :geo_state, :geo_blocked?, :geo_override_active?, :display_balance, :display_seeds_data, :onchain_session?, :wallet_context, :client_session_payload

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

  # Format-aware override of Studio::ErrorHandling#require_authentication.
  # The engine version unconditionally `redirect_to login_path`, which makes
  # Rails return 406 Not Acceptable for any AJAX request with
  # `Accept: application/json` (the HTML login page doesn't match the
  # requested format). The JS layer (solana_utils.authedFetch) already
  # knows how to handle a clean 401 — it opens the login modal — so emit
  # that for JSON/Turbo-Stream requests and keep the HTML redirect for
  # full-page navigations.
  def require_authentication
    return if logged_in?

    respond_to do |format|
      format.html         { redirect_to login_path }
      format.json         { render json: { error: "unauthenticated" }, status: :unauthorized }
      format.turbo_stream { head :unauthorized }
      format.any          { head :unauthorized }
    end
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

  # Payload serialised into #session-context for Alpine.store('session').
  # SessionContext stays pure (identity only); on-chain balances come from
  # @wallet_balances + @entry_token_balance which preload_navbar_solana_data
  # already populated for this request — no extra RPC.
  def client_session_payload
    wallet_context.to_h.merge(
      usdcCents:       wallet_field_cents(:usdc),
      usdtCents:       wallet_field_cents(:usdt),
      tokensAvailable: (current_user&.entry_token_balance.to_i rescue 0)
    )
  end

  def wallet_field_cents(key)
    dollars = @wallet_balances.is_a?(Hash) ? @wallet_balances[key] : nil
    ((dollars || 0).to_f * 100).round
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
  # Reuses @wallet_balances when preload_navbar_solana_data already
  # populated it for this request. Avoids running fetch_wallet_balances
  # twice in the same request.
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
  # Reuses @user_seeds when preload_navbar_solana_data already loaded it
  # for this request, avoiding a second sync_balance RPC.
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

  # Prefetches all on-chain data the navbar (+ admin dropdown) needs in
  # parallel, so the view phase has zero blocking Solana RPCs. Fires as a
  # before_action on every HTML request for a logged-in wallet user.
  # Thin wrapper around perform_solana_preload — only the gating logic
  # lives here so the underlying parallel fetch is reusable from JSON
  # endpoints (e.g. AccountsController#session_refresh).
  def preload_navbar_solana_data
    return unless request.format.html?
    return unless current_user&.solana_connected?

    perform_solana_preload
  end

  # The actual parallel-RPC fetch. Callable directly when a JSON endpoint
  # needs fresh on-chain state (e.g. after a write, for a client-side
  # refreshSession() refresh).
  #
  # Fans out 3 (or 4 for admins) RPCs in independent threads; total wall
  # time = max(N) instead of sum(N). Each thread gets its own
  # Solana::Vault.new (Net::HTTP isn't safe to share across threads) and is
  # wrapped in Rails.application.executor.wrap so the OutboundRequest
  # audit write gets a proper AR connection from the pool.
  #
  # Results are written to instance variables / Current so view helpers
  # (display_balance, display_seeds_data, User#entry_token_balance,
  # Solana::Vault.cached_vault_state) read prefetched values without
  # firing fresh RPCs.
  def perform_solana_preload
    return unless current_user&.solana_connected?

    t_total        = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    wallet_address = current_user.solana_address
    is_admin       = current_user.admin?

    balances_thread = Thread.new do
      Rails.application.executor.wrap do
        Solana::Vault.new.fetch_wallet_balances(wallet_address)
      rescue => e
        Rails.logger.warn("[preload] fetch_wallet_balances failed: #{e.message}")
        nil
      end
    end

    sync_thread = Thread.new do
      Rails.application.executor.wrap do
        Solana::Vault.new.sync_balance(wallet_address)
      rescue => e
        Rails.logger.warn("[preload] sync_balance failed: #{e.message}")
        nil
      end
    end

    tokens_thread = Thread.new do
      Rails.application.executor.wrap do
        Solana::Vault.new.list_entry_tokens(wallet_address).count { |tk| !tk[:consumed] }
      rescue => e
        Rails.logger.warn("[preload] entry_token_balance failed: #{e.message}")
        0
      end
    end

    vault_state_thread = if is_admin
      Thread.new do
        Rails.application.executor.wrap do
          Rails.cache.fetch("solana:vault_state", expires_in: 1.minute) do
            Solana::Vault.new.read_vault_state
          end
        rescue => e
          Rails.logger.warn("[preload] vault_state failed: #{e.message}")
          # Sentinel so the main thread can distinguish "confirmed nil"
          # (truly uninitialized) from "RPC errored" — vault_uninitialized?
          # fails safe to false in the latter case.
          :__preload_error__
        end
      end
    end

    @wallet_balances = balances_thread.value
    @user_seeds      = sync_thread.value&.dig(:seeds)
    current_user.instance_variable_set(:@entry_token_balance, tokens_thread.value)

    if vault_state_thread
      result = vault_state_thread.value
      Current.vault_state_fetched = true
      if result == :__preload_error__
        Current.vault_state_error = true
        Current.vault_state       = nil
      else
        Current.vault_state = result
      end
    end

    Rails.logger.info("[BENCH] perform_solana_preload total #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_total) * 1000).round}ms")
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
