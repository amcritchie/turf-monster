module Solana
  # Rails-session adapter around solana_studio's pure
  # Solana::AuthVerifier.verify!. Lives under app/controllers/concerns/ as
  # `Solana::SessionAuth` (NOT `Solana::AuthVerifier`) — the gem owns that
  # latter namespace, and Zeitwerk autoload skips colliding constants. By
  # keeping this concern under a distinct module name, both pieces of code
  # load reliably.
  #
  # Controllers `include Solana::SessionAuth` and call
  # `verify_solana_signature!(message:, signature_b58:, pubkey_b58:, session:)`.
  # This shim pulls/deletes the nonce from session (delete-before-verify =
  # replay protection) and delegates the cryptography to the gem.
  #
  # Errors raised by the gem (`Solana::AuthVerifier::VerificationError`) are
  # passed through unwrapped — controllers rescue that gem-defined constant
  # directly.
  module SessionAuth
    extend ActiveSupport::Concern

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
