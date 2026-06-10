class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
  include GeoHelper

  # Guard the JS-heavy *interactive* app against ancient browsers — but NOT the
  # public, shareable, crawlable pages. `allow_browser` 406s any UA it deems
  # non-modern, and link-preview fetchers (iMessage/Apple especially) present a
  # pinned OLD-Safari UA → they'd get 406 and never see the og tags, so shared
  # links never unfurl. Skipping these public GET pages lets previews work AND
  # stops bouncing a real visitor who lands on the funnel from an older phone.
  allow_browser versions: :modern, unless: :public_preview_request?

  before_action :verify_session_token  # OPSEC-045
  before_action :set_current_context
  before_action :capture_reference
  # Stamp activity right after auth resolves, BEFORE the geo/profile redirects —
  # an after_action is skipped when those before_actions halt the chain, so a
  # genuinely-active but redirected user would never get stamped.
  before_action :touch_last_seen
  before_action :detect_geo_state
  before_action :require_profile_completion
  before_action :preload_navbar_solana_data
  helper_method :geo_state, :geo_blocked?, :geo_override_active?, :display_balance, :display_seeds_data, :onchain_session?, :wallet_context, :client_session_payload, :true_user, :impersonating?

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
    # OPSEC-046: a fresh login must never inherit a prior impersonation — e.g. a
    # second admin re-authing (OAuth/wallet, which don't reset_session) over a
    # live impersonation on a shared browser. Logout already clears these.
    session.delete(:impersonated_user_id)
    session.delete(:true_admin_id)
    session.delete(:impersonation_started_at)
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
      format.html         { redirect_to signin_path }
      format.json         { render json: { error: "unauthenticated" }, status: :unauthorized }
      format.turbo_stream { head :unauthorized }
      format.any          { head :unauthorized }
    end
  end

  # ── Age attestation (underwriting compliance, 2026-06) ────────────────────
  # Every account-creation flow (magic link, Google OAuth, Solana wallet,
  # legacy POST /signup) must carry an affirmative legal-age attestation
  # before a User row is created. Existing users grandfather (login paths
  # never check). Shown to the user when a signup arrives without it.
  AGE_ATTESTATION_ERROR = "Please confirm you are of legal age to play " \
                          "skill-based contests in your state before creating an account.".freeze

  private

  # True only for an affirmative checkbox value ("1", "true", true). Each
  # signup controller reads its own source (params, omniauth.params, or the
  # MagicLink row) and funnels through this single truthiness rule.
  def age_attestation_given?(value = params[:age_attestation])
    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  # Public, crawlable GET pages that must unfurl in link previews (and never
  # 406 a visitor). These carry og/twitter tags and are the URLs people paste
  # into Messages/Slack/social: the marketing funnel + the public contest reads.
  # The interactive/authenticated app still gets the allow_browser guard.
  def public_preview_request?
    # HEAD is a bodyless GET — link-preview scanners (SafeLinks, iMessage,
    # Slack/social unfurlers) issue HEAD, so it must clear this guard exactly
    # like GET or those previews 406. (Brakeman VerbConfusion: request.get?
    # is false for HEAD even though HEAD routes like GET.)
    return false unless request.get? || request.head?
    return true if controller_name == "landing_pages"
    controller_name == "contests" && action_name.in?(%w[show world_cup index live])
  end

  # Stamp the REAL logged-in user's last activity (admin dashboard "by recent
  # session"). Throttled to one write per 5 min via update_column (no callbacks,
  # no updated_at churn) so it's cheap on the hot path; uses true_user so admin
  # impersonation never bumps the impersonated user's activity. Never raises.
  LAST_SEEN_THROTTLE = 5.minutes
  def touch_last_seen
    user = true_user
    return unless user
    return if user.last_seen_at && user.last_seen_at > LAST_SEEN_THROTTLE.ago

    user.update_column(:last_seen_at, Time.current)
  rescue => e
    Rails.logger.warn("[last_seen] #{e.class}: #{e.message}")
  end

  # ── Admin impersonation (OPSEC-046) ────────────────────────────────────────
  # An admin can "act as" a non-admin user for support / migration / a prod
  # smoke test. The admin's REAL session (Studio.session_key + :session_token)
  # is left untouched; only current_user resolution is layered on top. See
  # Admin::ImpersonationsController + the _impersonation_banner partial.
  # Truly functional ONLY for web2/managed users (the server signs with their
  # managed key); web3/Phantom targets are debug/read-only — no key to borrow.
  IMPERSONATION_MAX_MINUTES = 30

  # The real session owner — always the logged-in admin, never the impersonated
  # user. The OPSEC-045 token check + the admin gate bind to THIS.
  def true_user
    return @true_user if defined?(@true_user)
    @true_user = User.find_by(id: session[Studio.session_key])
  end

  # Overrides Studio::ErrorHandling#current_user: resolves to the impersonated
  # target while impersonating, else the true admin.
  def current_user
    return @current_user if defined?(@current_user)
    @current_user = impersonating? ? User.find_by(id: session[:impersonated_user_id]) : true_user
  end

  # Active only when a target is set, the real user is an admin, the target
  # exists + is NOT an admin + isn't the admin themselves, and the window
  # hasn't expired. Any failed guard transparently falls back to the admin.
  def impersonating?
    return @impersonating if defined?(@impersonating)
    @impersonating = compute_impersonating?
  end

  def compute_impersonating?
    imp = session[:impersonated_user_id]
    return false if imp.blank?
    return false unless true_user&.admin?

    # Fail closed: a blank/unparseable start time = expired, not "never expires".
    started = session[:impersonation_started_at]
    return false if started.blank? || Time.zone.parse(started.to_s) < IMPERSONATION_MAX_MINUTES.minutes.ago

    target = User.find_by(id: imp)
    target.present? && !target.admin? && target.id != true_user.id
  rescue
    false
  end

  # Bounce an already-authenticated viewer away from the auth-entry GET pages
  # (the /login + /signup form renders). A logged-in user landing on "Sign in
  # to play" is a dead end — send them to their account instead. Honours a
  # `?return_to` param if one is supplied (same key the login flow uses), but
  # only for in-app relative paths so it can't be used as an open-redirect.
  #
  # Apply this only to the form-render `:new` actions. It must NOT guard the
  # mid-auth callbacks (magic-link consume, OmniAuth callback, solana verify,
  # wallet-link landing, the POST create actions) — those legitimately run
  # while a session is being established and would be hijacked by a redirect.
  def redirect_if_authenticated
    return unless logged_in?

    redirect_to safe_return_to || account_path
  end

  # A `return_to` is honoured only when it's a relative, single-leading-slash
  # path (no scheme/host) — otherwise we ignore it to avoid open redirects.
  def safe_return_to
    target = params[:return_to].presence
    return nil unless target
    return nil unless target.start_with?("/") && !target.start_with?("//")

    target
  end

  # Populates Current.* for the request lifecycle so OutboundRequestLogger can
  # attribute Stripe / Solana calls back to the user without param threading.
  def set_current_context
    Current.user = current_user if logged_in?
    # OPSEC-046: real actor behind an impersonated session. Request-scoped, so
    # outbound calls in a background job spawned mid-impersonation won't carry it
    # (the in-request fund-touch — contest entry — is stamped; jobs are not).
    Current.true_admin = true_user if impersonating?
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
  # gets cleared before any downstream code reads current_user. Binds to
  # true_user (the real session owner), NOT current_user — admin impersonation
  # leaves the admin's cookie token in place while current_user resolves to the
  # target, so checking the target's token here would force-logout every request.
  def verify_session_token
    return unless true_user
    user_token   = true_user.session_token
    cookie_token = session[:session_token]

    return if user_token.present? && user_token == cookie_token

    Rails.logger.info("[opsec-045] session_token mismatch user_id=#{true_user.id} — forcing re-login")
    @current_user = nil
    @true_user = nil
    @impersonating = false
    clear_app_session
    respond_to do |format|
      format.html { redirect_to signin_path, alert: "Your session expired. Please sign in again." }
      format.json { render json: { error: "session expired" }, status: :unauthorized }
    end
  end

  # True when the current session was authenticated via Solana wallet signature
  # (not email/password). Set by SolanaSessionsController#verify. Forced false
  # while impersonating (OPSEC-046): an admin can't produce the target's Phantom
  # signature, and this stops the admin's real :onchain flag from leaking into
  # the impersonated view — forcing the web2/managed server-sign path for entries.
  def onchain_session?
    return false if impersonating?
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
  #
  # When the parallel preload's balances_thread silently returns nil (an
  # RPC flake — see perform_solana_preload), the cents fields are emitted
  # as null so the client-side eligibility check can recognise "unknown"
  # and fail open (let the server enforce) instead of zero-blocking a user
  # who actually has funds.
  def client_session_payload
    wallet_context.to_h.merge(
      usdcCents:       wallet_field_cents(:usdc),
      usdtCents:       wallet_field_cents(:usdt),
      tokensAvailable: (current_user&.entry_token_balance.to_i rescue 0)
    )
  end

  def wallet_field_cents(key)
    return 0 unless current_user            # guest — definitively 0

    if @wallet_balances.is_a?(Hash)
      return ((@wallet_balances[key] || 0).to_f * 100).round
    end

    # No preloaded balances on this render (the navbar preload no longer
    # blocks on the USDC/USDT RPC). Try the warm cache so a returning user
    # still gets a live eligibility hint; nil when cold → emitted as null so
    # eligibilityBlocker fails open (the server-side enter is authoritative).
    cached =
      case key
      when :usdc then Rails.cache.read(usdc_cache_key) if current_user.solana_connected?
      when :usdt then Rails.cache.read(usdt_cache_key) if current_user.solana_connected?
      end
    return nil if cached.nil?

    (cached.to_f * 100).round
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
  # NON-BLOCKING + cache-first: the render path NEVER issues a Solana RPC.
  # Returns:
  #   - the preloaded @wallet_balances[:usdc] when a specific page populated
  #     it explicitly (e.g. /wallet)
  #   - the cached USDC number (warm cache, written by the hydrate endpoint
  #     or a prior request) — Rails.cache.read, no fetch-on-miss
  #   - nil when the cache is cold ("loading" — the client-side refreshBalance
  #     fills the [data-balance-display] pill once it lands)
  #   - 0 for guests / non-wallet users (definitive)
  #
  # Memoized on the controller instance: views call this multiple times
  # across the navbar, layout, and action body.
  def display_balance
    return @display_balance if defined?(@display_balance)

    @display_balance =
      if @wallet_balances.is_a?(Hash) && @wallet_balances.key?(:usdc)
        @wallet_balances[:usdc] || 0
      elsif current_user&.solana_connected?
        # Cache-only read: warm → number, cold → nil ("loading"). Never a
        # blocking RPC on the render path.
        Rails.cache.read(usdc_cache_key)
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

  # Shared blocking fetch for the client-hydrate endpoints (AdminController
  # #usdc_balance + AccountsController#session_refresh). Fans the two uncached
  # Helius reads — wallet balances (USDC/USDT/SOL) and the seeds sync_balance —
  # out in parallel, WRITES the navbar caches (usdc/usdt/seeds), and returns a
  # hash of the values. Blocking is fine here: these run AFTER first paint, off
  # the render path. Each field is independently nil-safe (an RPC flake yields
  # nil for balances / 0 for seeds, never raises).
  def fetch_navbar_hydrate(user)
    address = user.solana_address

    balances_thread = Thread.new do
      Rails.application.executor.wrap do
        Solana::Vault.new.fetch_wallet_balances(address)
      rescue => e
        Rails.logger.warn("[hydrate] fetch_wallet_balances failed: #{e.message}")
        nil
      end
    end

    seeds_thread = Thread.new do
      Rails.application.executor.wrap do
        Solana::Vault.new.sync_balance(address)&.dig(:seeds)
      rescue => e
        Rails.logger.warn("[hydrate] sync_balance failed: #{e.message}")
        nil
      end
    end

    balances = balances_thread.value
    seeds    = seeds_thread.value

    if balances.is_a?(Hash)
      Rails.cache.write(usdc_cache_key(user), balances[:usdc] || 0, expires_in: 60.seconds)
      Rails.cache.write(usdt_cache_key(user), balances[:usdt] || 0, expires_in: 60.seconds)
    end
    unless seeds.nil?
      Rails.cache.write(seeds_cache_key(user), seeds_payload(seeds), expires_in: 60.seconds)
      # Sync the denormalized seeds/level cache on the users row (admin list
      # display + sort) from this fresh on-chain read — write-on-change only.
      user.update_level_from_seeds!(seeds)
    end

    {
      usdc:  balances.is_a?(Hash) ? (balances[:usdc] || 0) : nil,
      usdt:  balances.is_a?(Hash) ? (balances[:usdt] || 0) : nil,
      sol:   balances.is_a?(Hash) ? (balances[:sol]  || 0) : nil,
      seeds: seeds
    }
  end

  def usdc_cache_key(user = current_user)
    "usdc_balance:#{user.id}"
  end

  def usdt_cache_key(user = current_user)
    "usdt_balance:#{user.id}"
  end

  def invalidate_usdc_cache(user = current_user)
    Rails.cache.delete(usdc_cache_key(user))
  end

  # Navbar seeds bar — on-chain seed count for the logged-in user.
  # NON-BLOCKING + cache-first, same contract as display_balance:
  #   - preloaded @user_seeds when a page populated it explicitly
  #   - the cached seeds payload (warm cache) via Rails.cache.read
  #   - nil when cold ("loading") — the seeds bar falls back to its
  #     localStorage state and refreshBalance fills it
  #   - seeds_payload(0) for guests / non-wallet users (definitive)
  #
  # Per-request memoized: the navbar + seeds_bar partials both ask for this.
  def display_seeds_data
    return @display_seeds_data if defined?(@display_seeds_data)

    @display_seeds_data =
      if defined?(@user_seeds) && !@user_seeds.nil?
        seeds_payload(@user_seeds)
      elsif current_user&.solana_connected?
        # Cache-only read: warm → payload, cold → nil ("loading"). No RPC.
        Rails.cache.read(seeds_cache_key)
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

    # NOTE (async-navbar-balance): the wallet-balances (USDC/USDT) and the
    # seeds sync_balance RPCs are NO LONGER preloaded here. They were the two
    # uncached Helius calls that blocked every logged-in HTML render. The
    # navbar now renders cache-first (display_balance / display_seeds_data
    # read Rails.cache only) and the client hydrates them via refreshBalance()
    # → /admin/usdc_balance on page load. @wallet_balances / @user_seeds are
    # left unset (nil) so wallet_field_cents emits null cents (fail-open
    # eligibility hint) and the seeds bar uses its localStorage state.
    # KEPT below: the cached token count (60s) + the cached admin vault state
    # (1min) — both fast.

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

    # debug-level (not info) so this fires once per authenticated HTML
    # request without spamming prod logs. Bump to info temporarily when
    # investigating a preload regression.
    Rails.logger.debug("[BENCH] perform_solana_preload total #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_total) * 1000).round}ms")
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

  # Shared server-side guard for user-supplied image uploads (avatars, contest
  # banners). The browser always crops to a valid PNG before posting, so this is
  # defense-in-depth against a forged/direct multipart POST — and the only
  # server-side gate, since neither User#avatar nor Contest#contest_image
  # declares an attachment validation.
  IMAGE_UPLOAD_TYPES = %w[image/png image/jpeg image/webp].freeze

  def valid_image?(file, types: IMAGE_UPLOAD_TYPES, max: 8.megabytes)
    file.respond_to?(:content_type) && file.respond_to?(:size) &&
      types.include?(file.content_type) && file.size <= max
  end
end
