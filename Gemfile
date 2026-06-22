source "https://rubygems.org"

ruby "3.3.11"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 7.2.2", ">= 7.2.2.1"
# The original asset pipeline for Rails [https://github.com/rails/sprockets-rails]
gem "sprockets-rails"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"
# Redis adapter for Action Cable — powers contest chat real-time delivery.
gem "redis", ">= 4.0.1"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Google OAuth
gem "omniauth"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection", "~> 1.0"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ mswin mswin64 mingw x64_mingw jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"
gem "aws-sdk-s3", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri mswin mswin64 mingw x64_mingw ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Pretty-print Stripe payloads + on-chain responses in tagged dev logs.
  gem "amazing_print"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  # I1 (Stage 3 audit): code coverage. Opt-in via COVERAGE=1 — see test_helper.rb.
  gem "simplecov", require: false
end
gem "dotenv-rails", groups: [:development, :test]
gem "tailwindcss-rails", "~> 4.5"
# Sidekiq + scheduled jobs (Reconciler cron, ATA ensure jobs, deposit jobs)
gem "sidekiq-cron", "~> 1.12"

# Sentry — production error monitoring. ErrorLog.capture! fans out to Sentry
# when SENTRY_DSN env var is set. No-op if absent.
gem "sentry-ruby"
gem "sentry-rails"

# Shared Rails engine: auth, theme, error logs, SSO, and the unified
# Studio::Link store (short tokens for magic links + referral invites).
# 0.8.0 publishes the standard Studio::Link model adopted here.
gem "studio-engine", "~> 0.8"

# Solana primitives (Client, Keypair, Borsh, Transaction, AuthVerifier)
# 0.4.7 adds Solana::Transaction.cosign_wire + Client#simulate_transaction for the
# Phantom-first signing-order flow (published to RubyGems).
gem "solana-studio", "~> 0.4.7"

# IP geolocation for state-level geo-blocking
gem "geocoder"

# Random username generation for new wallet-only users (via Studio::UsernameGenerator)
gem "faker"

# Background jobs
gem "sidekiq"

# Payment processing
gem "stripe"

# EdDSA (Ed25519) signing for JWTs — required by Cdp::Auth for Coinbase CDP
# Onramp/Offramp REST auth. jwt 3.x extracted EdDSA support into this gem;
# vanilla jwt raises JWT::EncodeError ("Unsupported signing method") without it.
# Pinned: third-party gem (anakinj) sitting on the CDP secret-key signing path.
# See docs/CDP_RAMP_INTEGRATION.md §1.
gem "jwt-eddsa", "~> 0.9"

# Request throttling (OPSEC-019). Rack middleware that rate-limits per IP /
# per user / per endpoint. Configured in config/initializers/rack_attack.rb.
# Disabled in test env (so tests don't hit throttles by accident).
gem "rack-attack"
