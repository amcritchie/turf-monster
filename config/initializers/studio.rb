Studio.configure do |config|
  config.app_name = "Turf Monster"
  config.session_key = :turf_user_id
  config.welcome_message = ->(user) { "Welcome to Turf Monster, #{user.display_name}!" }
  config.registration_params = [:email, :password, :password_confirmation, :reference]
  config.configure_new_user = ->(user) { }
  config.configure_sso_user = ->(user) { }

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
