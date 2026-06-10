require "test_helper"

# Wallet auth signup boundary (SolanaSessionsController#verify is
# create-or-login). The legal-age attestation (underwriting compliance) must
# accompany any verify that would CREATE an account; existing wallets are a
# plain login and are unaffected. (The existing-user login path itself is
# exercised constantly via test_helper's log_in_as_onchain.)
class SolanaSessionsControllerTest < ActionDispatch::IntegrationTest
  # Build a fresh keypair + signed SIWS message for a wallet that has NO user
  # row yet — the signup side of verify (log_in_as_onchain covers login).
  def signed_verify_params
    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    host = "www.example.com"
    message = "#{host} wants you to sign in with your Solana account:\n#{pubkey_b58}\n\nNonce: #{nonce}"
    sig_b58 = Solana::Keypair.encode_base58(key.sign(message))

    { message: message, signature: sig_b58, pubkey: pubkey_b58 }
  end

  test "verify creates an account for a new wallet WITH the legal-age attestation" do
    params = signed_verify_params
    assert_difference "User.count", 1 do
      post "/auth/solana/verify", params: params.merge(age_attestation: "1"), as: :json
    end
    assert_response :success
    assert JSON.parse(response.body)["success"]

    user = User.find_by(web3_solana_address: params[:pubkey])
    assert user.age_attested_at.present?, "wallet signup must stamp the legal-age attestation"
    assert_equal user.id, session[:turf_user_id]
  end

  test "verify REFUSES to create an account for a new wallet without the attestation" do
    params = signed_verify_params
    assert_no_difference "User.count" do
      post "/auth/solana/verify", params: params, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/legal age/i, JSON.parse(response.body)["error"])
    assert_nil session[:turf_user_id], "no session may be established"
  end

  test "verify still logs in an existing wallet user without any attestation (grandfathered)" do
    user = users(:sam)
    key = log_in_as_onchain(user) # creates the address + logs in via verify
    assert_equal user.id, session[:turf_user_id]
    assert_nil user.reload.age_attested_at, "login must not stamp attestation"
    assert key, "helper returns the signing key"
  end
end
