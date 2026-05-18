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

  get "toast_test", to: "toast_test#index"
  post "toast_test/flash", to: "toast_test#trigger_flash"
  get "turf-totals-v1", to: "pages#turf_totals_v1", as: :turf_totals_v1

  # Public faucet page
  get  "faucet", to: "faucet#show", as: :faucet
  post "faucet", to: "faucet#claim"

  # Help center
  get "help",              to: "help#index",       as: :help
  get "help/how-to-play",  to: "help#how_to_play", as: :help_how_to_play
  get "help/phantom",      to: "help#phantom",     as: :help_phantom
  get "help/glossary",     to: "help#glossary",    as: :help_glossary

  # Phantom deep link callback — must be before Studio.routes to avoid
  # matching OmniAuth's /auth/:provider/callback wildcard
  get  "auth/phantom/callback", to: "solana_sessions#phantom_callback"

  Studio.routes(self)

  # Solana wallet auth
  get  "auth/solana/nonce",  to: "solana_sessions#nonce"
  post "auth/solana/verify", to: "solana_sessions#verify"

  # Account management
  resource :account, only: [:show, :update] do
    get :complete_profile
    post :save_profile
    post :link_solana
    post :unlink_google
    post :change_password
    patch :set_inviter
    patch :update_level
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

  get "c/:id/lobby", to: "contests#lobby", as: :contest_lobby
  get "c/:id/leaderboard_poll", to: "contests#leaderboard_poll", as: :contest_leaderboard_poll

  resources :contests, only: [:index, :show, :new, :create, :edit, :update] do
    collection do
      get :my
      get :generator
    end
    member do
      post :toggle_selection
      post :enter
      post :prepare_entry
      post :confirm_onchain_entry
      post :clear_picks
      post :grade
      post :fill
      post :lock
      post :jump
      post :simulate_game
      post :simulate_batch
      post :reset
      post :prepare_onchain_contest
      post :confirm_onchain_contest
      post :payout_entry
    end
  end

  resources :teams, only: [:index, :show]
  resources :players, only: [:index]
  resources :games, only: [:index]

  resource :wallet, only: [:show] do
    post :deposit
    post :stripe_deposit
    post :moonpay_deposit
    post :withdraw
    post :faucet
    post :airdrop
    get :sync
  end

  # Payment webhooks
  post "webhooks/stripe", to: "webhooks/stripe#create"
  post "webhooks/moonpay", to: "webhooks/moonpay#create"

  post "add_funds", to: "users#add_funds"

  # Admin: Treasury (pending multisig transactions)
  namespace :admin do
    resources :pending_transactions, only: [:index, :show], param: :slug do
      member do
        post :confirm
        post :rebuild
      end
    end

    resources :slates, only: [], param: :slug do
      member { get :manage }
    end

    resources :games, only: [], param: :slug do
      member do
        post :record_goal, path: "goals"
        delete :remove_goal, path: "goals/:id"
        post :complete_game, path: "complete"
      end
    end
  end

  # Admin: Navbar review
  get "admin/navbar", to: "admin#navbar", as: :admin_navbar

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
end
