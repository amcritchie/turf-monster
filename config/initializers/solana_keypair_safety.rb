# OPSEC-021: Redact `Solana::Keypair#inspect` and `#to_s` so the 64-byte
# private key never lands in logs, Sentry frame locals, awesome_print dumps,
# or anywhere an object's default inspect output might be captured.
#
# This is a turf-monster-local guard. A corresponding change should land in
# the `solana-studio` gem itself in a follow-up release; until then this
# initializer protects every code path in this app.
#
# Background: `Solana::Keypair` holds the secret in instance variables (e.g.
# `@signing_key`, `@secret_key_bytes`). Ruby's default `Object#inspect`
# prints every ivar — which means a single `Rails.logger.info(keypair)` or
# an exception captured by Sentry with the keypair in scope would exfiltrate
# the secret.

Rails.application.config.after_initialize do
  next unless defined?(Solana::Keypair)

  Solana::Keypair.class_eval do
    def inspect
      addr = to_base58 rescue "<unknown>"
      "#<Solana::Keypair pubkey=#{addr[0, 8]}…>"
    end

    def to_s
      inspect
    end

    # `pp` and friends call `pretty_print` if defined.
    def pretty_print(pp)
      pp.text(inspect)
    end
  end
end
