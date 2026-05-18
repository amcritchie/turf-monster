class SolanaSessionsController < ApplicationController
  include Solana::SessionAuth
  skip_before_action :require_authentication

  def nonce
    session[:solana_nonce] = SecureRandom.hex(16)
    session[:solana_nonce_at] = Time.current.to_i
    render json: { nonce: session[:solana_nonce] }
  end

  def phantom_callback
    # Client-side only — JS handles decryption and verify POST
  end

  def verify
    pubkey_b58 = verify_solana_signature!(
      message: params[:message],
      signature_b58: params[:signature],
      pubkey_b58: params[:pubkey],
      session: session
    )

    # Find or create user with this Solana address
    user = User.from_solana_wallet(pubkey_b58)
    is_new = user.nil?

    user ||= User.new(
      name: "anon",
      username: Studio::UsernameGenerator.generate,
      web3_solana_address: pubkey_b58,
      password: SecureRandom.hex(16)
    )

    rescue_and_log(target: user) do
      user.save! if user.new_record?
      set_app_session(user)
      session[:onchain] = true
      render json: { success: true, redirect: "/", new_user: is_new }
    end
  rescue Solana::AuthVerifier::VerificationError => e
    render json: { error: e.message }, status: :unauthorized
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
