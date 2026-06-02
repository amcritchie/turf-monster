ENV["RAILS_ENV"] ||= "test"

# I1 (Stage 3 audit): SimpleCov must start before Rails loads any app code
# so it can track which lines get hit. Opt-in via COVERAGE=1 to keep the
# default `bin/rails test` fast. Threshold enforcement is separately opt-in
# (ENFORCE_COVERAGE=1) because parallel worker fragmentation makes the
# aggregate look artificially low — read per-file numbers in
# coverage/index.html to set realistic minimums.
if ENV["COVERAGE"] == "1" || ENV["CI"]
  require "simplecov"
  SimpleCov.start "rails" do
    command_name "Worker #{ENV['TEST_ENV_NUMBER'] || '0'}"
    merge_timeout 3600
    enable_coverage :branch
    add_group "Models",      "app/models"
    add_group "Controllers", "app/controllers"
    add_group "Webhooks",    "app/controllers/webhooks"
    add_group "Jobs",        "app/jobs"
    add_group "Services",    "app/services"
    add_filter "/test/"
    add_filter "/config/"
    add_filter "/db/"
    add_filter "/vendor/"
    minimum_coverage(line: 70) if ENV["ENFORCE_COVERAGE"] == "1"
  end
end

require_relative "../config/environment"
require "rails/test_help"

# Shared test doubles. test/support/* is auto-loaded so individual test
# files don't need to require_relative them.
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

OmniAuth.config.test_mode = true

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
    fixtures :all
  end
end

class ActionDispatch::IntegrationTest
  # OmniAuth.config is a PROCESS-GLOBAL singleton shared by every test in a
  # parallel worker. TestController#reseed (hit by TestControllerTest's
  # `post /test/reseed`, and by Playwright at runtime) flips
  # `test_mode = false` + clears mock_auth to model the real-Google dev flow
  # (commit 85a6870). Without a per-test reset, whichever OmniAuth callback
  # test the worker happens to run *after* that reseed lands on the real
  # OAuth2 strategy and fails with `csrf_detected` — the state check the mock
  # path skips. Re-assert the test baseline before every integration test so
  # worker sharding / ordering can't make OmniAuth flaky. Per-class setups run
  # after this (parent callbacks fire first), so they still layer their own
  # mock_auth on top of the cleared hash.
  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth.clear
  end

  # Passwordless: email auth is magic-link only. Logging in = mint a magic-link
  # token the same way MagicLinksController#create does, then GET the consume
  # URL to establish the session (existing email user → sign_in_existing).
  # Signature kept as log_in_as(user) so the many call sites are unchanged.
  #
  # MagicLinksController#sign_in_existing stamps email_verified_at when blank
  # (clicking the link IS proof of ownership). That's correct product behavior
  # but a test that deliberately set email_verified_at: nil shouldn't have the
  # mere act of authenticating silently flip it — so we preserve whatever
  # verification state the test arranged before the consume.
  def log_in_as(user)
    raise ArgumentError, "log_in_as requires a user with an email (use log_in_as_onchain for wallet users)" if user.email.blank?
    verified_before = user.email_verified_at
    token = MagicLink.generate(email: user.email)
    get magic_link_path(token: token)
    user.update_column(:email_verified_at, verified_before) if user.reload.email_verified_at != verified_before
  end

  # Log in via Solana wallet auth — sets session[:onchain] = true
  # Returns the Ed25519 signing key for use in subsequent signature proofs
  def log_in_as_onchain(user)
    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    user.update!(web3_solana_address: pubkey_b58)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    host = "www.example.com"
    message = "#{host} wants you to sign in with your Solana account:\n#{pubkey_b58}\n\nNonce: #{nonce}"
    sig_b58 = Solana::Keypair.encode_base58(key.sign(message))

    post "/auth/solana/verify", params: { message: message, signature: sig_b58, pubkey: pubkey_b58 }, as: :json
    assert_response :success, "Onchain login failed: #{response.body}"

    key
  end

  # Sign a contest entry message with the given key, returning params hash for POST /enter
  def sign_entry_message(key, user, contest_name)
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    host = "www.example.com"
    # OPSEC-005: signed message must embed `User-ID: <id>` so the server
    # binds the signature to the active session's user.
    message = "#{host} wants you to sign in with your Solana account:\n#{pubkey_b58}\n\nUser-ID: #{user.id}\n\nEnter contest: #{contest_name}\n\nNonce: #{nonce}"
    sig_b58 = Solana::Keypair.encode_base58(key.sign(message))

    { message: message, signature: sig_b58, pubkey: pubkey_b58 }
  end
end
