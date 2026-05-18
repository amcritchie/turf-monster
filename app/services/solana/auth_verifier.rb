module Solana
  # Thin Rails-session adapter around solana_studio's pure
  # Solana::AuthVerifier.verify!.
  #
  # Controllers `include Solana::AuthVerifier` and call
  # `verify_solana_signature!(message:, signature_b58:, pubkey_b58:, session:)`.
  # This shim pulls/deletes the nonce from session (delete-before-verify =
  # replay protection) and delegates the cryptography to the gem.
  #
  # `VerificationError` and `NONCE_MAX_AGE` come from the gem.
  module AuthVerifier
    def verify_solana_signature!(message:, signature_b58:, pubkey_b58:, session:)
      # Delete nonce BEFORE verification to prevent replay
      stored_nonce = session.delete(:solana_nonce)
      nonce_at     = session.delete(:solana_nonce_at)

      ::Solana::AuthVerifier.verify!(
        message:       message,
        signature_b58: signature_b58,
        pubkey_b58:    pubkey_b58,
        stored_nonce:  stored_nonce,
        nonce_at:      nonce_at
      )
    end
  end
end
