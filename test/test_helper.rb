ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

OmniAuth.config.test_mode = true

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
    fixtures :all
  end
end

class ActionDispatch::IntegrationTest
  def log_in_as(user, password: "password")
    post login_path, params: { email: user.email, password: password }
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
