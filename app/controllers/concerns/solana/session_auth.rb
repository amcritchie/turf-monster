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

    def verify_solana_signature!(message:, signature_b58:, pubkey_b58:, session:, expected_user_id: nil)
      # OPSEC-005: when the caller is authenticated, require the signed
      # message to embed `User-ID: <current_user.id>` so a signature
      # captured against a *different* session's nonce can't be replayed
      # into this user's flow. Login (solana_sessions#verify) calls without
      # expected_user_id since there's no current_user yet — the nonce
      # delete-before-verify below remains replay protection for that path.
      if expected_user_id && !message.to_s.include?("User-ID: #{expected_user_id}")
        raise ::Solana::AuthVerifier::VerificationError,
              "Signed message missing User-ID binding for current session"
      end

      # Delete nonce BEFORE verification to prevent replay
      stored_nonce = session.delete(:solana_nonce)
      nonce_at     = session.delete(:solana_nonce_at)

      # OPSEC-018: bind the signature to this host. The client builds the
      # message with `window.location.host`; request.host_with_port is the
      # server-side equal (hostname, plus port only when non-default).
      ::Solana::AuthVerifier.verify!(
        message:       message,
        signature_b58: signature_b58,
        pubkey_b58:    pubkey_b58,
        expected_host: request.host_with_port,
        stored_nonce:  stored_nonce,
        nonce_at:      nonce_at
      )
    end
  end
end
