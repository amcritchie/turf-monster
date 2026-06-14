# Passwordless (Lazarus audit #4): this app removed has_secure_password — email
# auth is magic-link only (wallet auth via SolanaSessionsController unchanged).
# The studio-engine User contract still requires User#authenticate, which no
# longer exists, so we opt out of the contract check. The engine's password
# SessionsController#create is fully overridden by the host (bounces to the
# magic-link flow), so no engine code path relies on #authenticate here.
Studio.validate_user_contract = false

# This app defines its own magic_link + solana routes (with extras like
# email_verification, phantom_callback, google_popup, link_wallet) in
# config/routes.rb, so the engine must NOT also draw its magic_link/solana
# routes — that would collide on the `magic_link` route NAME and crash boot.
# (studio-engine >= 0.5.1)
Studio.draw_auth_routes = false

Studio.configure do |config|
  config.app_name = "Turf Monster"
  config.session_key = :turf_user_id
  config.welcome_message = ->(user) { "Welcome to Turf Totals, #{user.display_name}!" }
  # Passwordless: email auth is magic-link only. Permit just :email (+ funnel
  # reference) so the engine's POST /signup path can't choke on now-unsupported
  # password params (there is no password= setter anymore).
  config.registration_params = [:email, :reference]
  config.configure_new_user = ->(user) { }
  config.configure_sso_user = ->(user) { }
  config.mailer_from = ENV.fetch("MAILER_FROM", "alex@turfmonster.media")

  config.theme_logos = [
    { file: "favicon.png",   title: "Favicon" },
    { file: "logo.png",      title: "Navbar Logo" },
    { file: "logo.jpeg",     title: "Auth Logo" },
  ]

  # Theme: green primary, violet as accent2
  config.theme_primary = "#4BAF50"
  config.theme_accent = "#8E82FE"

  # S3 — overrides engine default ("mcritchie-studio") to use this app's bucket
  config.s3_bucket_prefix = "turf-monster"
end
