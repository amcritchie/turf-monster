require "sidekiq/web"

# Back-to-app link in Sidekiq header
Sidekiq::Web.app_url = "/"

# Admin-only session guard — redirects non-admins to login
class SidekiqAdminMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    session = env["rack.session"] || {}
    user_id = session[Studio.session_key.to_s] || session[Studio.session_key]
    user = user_id && User.find_by(id: user_id)

    if user&.admin?
      @app.call(env)
    else
      body = <<~HTML
        <!DOCTYPE html>
        <html>
        <head><title>Not Found</title></head>
        <body style="background:#1A1535; color:#f8fafc; font-family:system-ui,sans-serif; display:flex; align-items:center; justify-content:center; min-height:100vh; margin:0;">
          <div style="text-align:center;">
            <p style="font-size:4rem; margin:0;">&#129300;</p>
            <h1 style="font-size:1.5rem; margin:1rem 0 0.5rem;">You look lost</h1>
            <p style="color:#94a3b8; margin-bottom:1.5rem;">There's nothing to see here.</p>
            <a href="/" style="background:#4BAF50; color:#fff; padding:0.5rem 1.5rem; border-radius:0.5rem; text-decoration:none; font-weight:bold;">Take me home</a>
          </div>
        </body>
        </html>
      HTML
      [404, { "Content-Type" => "text/html" }, [body]]
    end
  end
end

Sidekiq::Web.use SidekiqAdminMiddleware

Rails.application.routes.draw do
  mount Sidekiq::Web => "/admin/jobs"

  get "up" => "rails/health#show", as: :rails_health_check
  root "contests#world_cup"

  # Prelaunch audit M14 (2026-05-24): dev-only tools — not drawn in production
  # so they don't leak surface area on the public-mainnet app. Drawn in dev +
  # test (so existing template URL helpers continue resolving in the test env).
  unless Rails.env.production?
    get  "toast_test",       to: "toast_test#index"
    post "toast_test/flash", to: "toast_test#trigger_flash"
    get  "seeds_lab",        to: "seeds_lab#index", as: :seeds_lab
  end

  get "turf-totals-v1", to: "pages#turf_totals_v1", as: :turf_totals_v1
  get "terms",          to: "pages#terms",          as: :terms

  # Public proof-of-reserves — reads on-chain Contest PDAs and the shared
  # vault USDC token account from the browser via Solana RPC, then displays
  # them next to the Rails-reported figures.
  get "proof-of-reserves", to: "proof_of_reserves#show", as: :proof_of_reserves

  # Public faucet page
  get  "faucet", to: "faucet#show", as: :faucet
  post "faucet", to: "faucet#claim"

  # Help center
  get "help",              to: "help#index",       as: :help
  get "help/how-to-play",  to: "help#how_to_play", as: :help_how_to_play
  get "help/phantom",      to: "help#phantom",     as: :help_phantom
  get "help/glossary",     to: "help#glossary",    as: :help_glossary

  # Landing pages — public funnel pages (admin-managed via Admin::LandingPagesController)
  get "l/:slug", to: "landing_pages#show", as: :landing_page

  # Phantom deep link callback — must be before Studio.routes to avoid
  # matching OmniAuth's /auth/:provider/callback wildcard
  get  "auth/phantom/callback", to: "solana_sessions#phantom_callback"

  Studio.routes(self)

  # Solana wallet auth
  get  "auth/solana/nonce",  to: "solana_sessions#nonce"
  post "auth/solana/verify", to: "solana_sessions#verify"

  # Wallet-login landing for a Google sign-in that collided with a wallet
  # account — see OmniauthCallbacksController#create.
  get  "login/wallet",       to: "solana_sessions#link_wallet", as: :link_wallet

  # Google OAuth popup entrypoint — sets a popup-mode session flag, then
  # hands off to OmniAuth. The callback renders a window-closer page.
  get "auth/google_popup", to: "omniauth_callbacks#popup"

  # Inline (modal) email+password login — JSON only, returns user info
  # so the caller can replay cart selections and submit entry.
  post "sessions/inline", to: "inline_sessions#create", as: :inline_login

  # Inline (modal) email+password signup — JSON only. Mirrors the login
  # route above; creates the account, then the caller resumes the cart.
  post "registrations/inline", to: "inline_registrations#create", as: :inline_signup

  # Email verification (OPSEC-005). Tokens are message_verifier blobs that
  # contain dots; constraints: { token: /.+/ } stops Rails from interpreting
  # them as URL format extensions.
  get  "email_verification/new",       to: "email_verifications#new",    as: :email_verifications_new
  post "email_verification",           to: "email_verifications#create", as: :email_verifications
  get  "email_verification/:token",    to: "email_verifications#verify", as: :email_verifications_verify,
       constraints: { token: %r{[^/]+} }, format: false

  # Account management
  resource :account, only: [:show, :update] do
    get :complete_profile
    post :save_profile
    post :link_solana
    post :unlink_google
    post :change_password
    patch :set_inviter
    post :update_username   # on-chain username edit (custodial server-signs / Phantom co-signs)
    post :confirm_username  # Phantom: confirm the co-signed set_username TX
    get :session_state, defaults: { format: :json } # visibilitychange rehydrate
    get :session_refresh, defaults: { format: :json } # on-chain state for refreshSession()
    # OPSEC-007: removed `patch :update_level` — client-supplied seeds_total.
  end

  resources :slates, only: [:index, :show] do
    member do
      patch :update_rankings
      patch :update_turf_scores
      patch :update_formula
    end
    collection do
      get :formula_report
      get :admin_formula
      patch :update_admin_formula
    end
  end

  get "c/:id/leaderboard_poll", to: "contests#leaderboard_poll", as: :contest_leaderboard_poll

  resources :contests, only: [:index, :show, :new, :create, :edit, :update] do
    collection do
      get :my
      get :generator
      post :generate_bundle
      post :finalize_bundle
      post :finalize
    end
    member do
      post :toggle_selection
      post :pick
      post :enter
      post :prepare_entry
      post :stamp_entry_signature
      post :recover_pending_entry
      post :confirm_onchain_entry
      post :clear_picks
      post :grade
      post :grade_round
      post :fill
      post :lock
      post :jump
      post :simulate_game
      post :simulate_batch
      post :reset
      post :prepare_onchain_contest
      post :confirm_onchain_contest
      # `post :payout_entry` was removed in the 2026-05-23 audit (H2) —
      # see ContestsController for context.
    end

    # Contest chat — create (entrants/admins) + destroy (admin soft-delete).
    resources :messages, only: [:create, :destroy]
  end

  resources :teams, only: [:index, :show]
  resources :players, only: [:index]
  resources :games, only: [:index]

  resource :wallet, only: [:show] do
    get  :topup
    post :stripe_deposit
    post :moonpay_deposit
    post :withdraw
    post :faucet
    post :airdrop
    get  :sync
  end

  # Entry tokens (web2 contest-entry currency)
  get  "tokens/buy",             to: "tokens#buy",             as: :tokens_buy
  post "tokens/stripe_checkout", to: "tokens#stripe_checkout", as: :tokens_stripe_checkout
  get  "tokens/processing",      to: "tokens#processing",      as: :tokens_processing
  get  "tokens/status",          to: "tokens#status",          as: :tokens_status
  post "tokens/dev_mint",        to: "tokens#dev_mint",        as: :tokens_dev_mint

  # Payment webhooks
  post "webhooks/stripe", to: "webhooks/stripe#create"
  post "webhooks/moonpay", to: "webhooks/moonpay#create"

  post "add_funds", to: "users#add_funds"

  # Admin: Treasury (pending multisig transactions)
  namespace :admin do
    # User browser — refer chain, invitees count, audit columns. Read-only.
    resources :users, only: [:index]

    # Site-wide singleton config — currently just the main_contest pointer,
    # but the page is the canonical home for any future global setting that
    # doesn't fit on a per-record edit form.
    get   "site_config", to: "site_configs#show",   as: :site_config
    patch "site_config", to: "site_configs#update"

    resources :outbound_requests, only: [:index, :show]

    # Landing pages — funnel page manager (public pages live at /l/:slug)
    resources :landing_pages, only: %i[index new create edit update destroy], param: :slug

    resources :pending_transactions, only: [:index, :show], param: :slug do
      member do
        post :confirm
        post :rebuild
      end
    end

    resources :slates, only: [], param: :slug do
      member { get :manage }
    end

    # Free entries (on-chain token minting console)
    get  "free_entries",                       to: "free_entries#index",    as: :free_entries
    post "free_entries/:user_slug/mint",       to: "free_entries#mint",     as: :mint_free_entries
    post "free_entries/mint_all",              to: "free_entries#mint_all", as: :mint_all_free_entries

    # Vault init (one-time mainnet setup — Phantom cosigns as INIT_AUTHORITY)
    get  "vault_init",                         to: "vault_init#show",       as: :vault_init
    post "vault_init/build",                   to: "vault_init#build",      as: :build_vault_init
    post "vault_init/confirm",                 to: "vault_init#confirm",    as: :confirm_vault_init

    # Vault state — pause / unpause (M5, v0.15.0). Emergency stop for
    # user-facing funds operations. 2-of-3 cosign; same direct-cosign
    # pattern as vault_init.
    get  "vault_state",                        to: "vault_state#show",      as: :vault_state
    post "vault_state/pause",                  to: "vault_state#pause",     as: :pause_vault_state
    post "vault_state/unpause",                to: "vault_state#unpause",   as: :unpause_vault_state
    post "vault_state/confirm",                to: "vault_state#confirm",   as: :confirm_vault_state

    # Seasons (on-chain seed schedule template)
    get  "seasons",                            to: "seasons#index",         as: :seasons
    post "seasons",                            to: "seasons#create"
    post "seasons/:season_id/set_current",     to: "seasons#set_current",   as: :set_current_season

    resources :games, only: [], param: :slug do
      member do
        post :record_goal, path: "goals"
        delete :remove_goal, path: "goals/:id"
        post :complete_game, path: "complete"
      end
    end
  end

  # Admin: Link hub — central index of admin tools + actions
  get "admin/hub", to: "admin#hub", as: :admin_hub

  # Admin: Navbar review
  get "admin/navbar", to: "admin#navbar", as: :admin_navbar

  # Admin: Level badges preview gallery (1–10)
  get "admin/level_badges", to: "admin#level_badges", as: :admin_level_badges

  # Admin: Modal gallery — grid of every modal partial / state variant
  # rendered in isolated iframes (see AdminController::MODAL_VARIANTS).
  get "admin/modals", to: "admin#modals", as: :admin_modals
  get "admin/modals/preview/:modal_id", to: "admin#modal_preview", as: :admin_modal_preview
  get "admin/modals/preview_crop", to: "admin#modal_preview_crop", as: :admin_modal_preview_crop

  # Admin: Mint USDC (devnet) + balance check
  post "admin/mint_usdc", to: "admin#mint_usdc", as: :admin_mint_usdc
  get "admin/usdc_balance", to: "admin#usdc_balance", as: :admin_usdc_balance

  # Admin: Contests

  # Admin: Transaction Logs
  get "admin/transactions", to: "transaction_logs#index", as: :admin_transactions
  get "admin/transactions/:slug", to: "transaction_logs#show", as: :admin_transaction
  post "admin/transactions/:slug/approve", to: "transaction_logs#approve", as: :admin_transaction_approve
  post "admin/transactions/:slug/deny", to: "transaction_logs#deny", as: :admin_transaction_deny
  post "admin/transactions/:slug/complete", to: "transaction_logs#complete", as: :admin_transaction_complete

  # Geo check (public — used by hold-to-confirm validation)
  get "geo/check", to: "geo_settings#check", as: :geo_check

  # Admin: Geo Settings
  get "admin/geo", to: "geo_settings#edit", as: :admin_geo
  patch "admin/geo", to: "geo_settings#update", as: :admin_geo_update
  post "admin/geo/toggle", to: "geo_settings#toggle_override", as: :admin_geo_toggle

  # Test-only endpoints — exercised by Playwright e2e specs to seed
  # OAuth mock payloads and force referral cache values without staging
  # full signup flows. Guarded by Rails.env.test? so they never exist
  # outside the test boot.
  if Rails.env.test?
    post "test/oauth_mock",               to: "test#set_oauth_mock"
    post "test/set_user_referral_counts", to: "test#set_user_referral_counts"
    post "test/create_active_entry",      to: "test#create_active_entry"
    get  "test/user_info/:slug",          to: "test#user_info"
  end
end
