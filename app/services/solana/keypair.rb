# Rails-specific extensions to Solana::Keypair (from the solana-studio gem).
# Adds admin keypair loading + versioned encrypt/decrypt for DB storage.
#
# OPSEC-015 — managed-wallet private keys are encrypted at rest in
# users.encrypted_web2_solana_private_key. The key material now comes from
# MANAGED_WALLET_ENCRYPTION_KEY (a dedicated env var, independent of
# RAILS_MASTER_KEY / secret_key_base) run through ActiveSupport::KeyGenerator
# for a full 256-bit AES key. Ciphertexts are version-tagged ("v2:") so the
# scheme is rotatable: `from_encrypted` still decrypts legacy untagged
# ciphertexts via the old secret_key_base derivation, and
# `bin/rails solana:reencrypt_managed_wallets` migrates them forward.
#
# Pre-OPSEC-015 the key was `secret_key_base[0, 32]` — 32 hex *characters*,
# i.e. only ~128 bits of real entropy, and impossible to rotate without
# orphaning every stored wallet key.

module Solana
  class Keypair
    ENCRYPTION_VERSION = "v2".freeze

    # Load admin keypair from SOLANA_ADMIN_KEY env var (base58)
    def self.admin
      @admin ||= if ENV["SOLANA_ADMIN_KEY"].present?
        from_base58(ENV["SOLANA_ADMIN_KEY"])
      else
        raise "SOLANA_ADMIN_KEY env var required"
      end
    end

    # Load from an encrypted string. Handles the current "v2:"-tagged scheme
    # and legacy untagged ciphertexts transparently.
    def self.from_encrypted(encrypted_string)
      version, payload = parse_encrypted(encrypted_string)
      decrypted = encryptor_for(version).decrypt_and_verify(payload)
      from_bytes(Base64.strict_decode64(decrypted))
    end

    # Encrypt for DB storage — always produces a current-version ciphertext.
    def encrypt
      self.class.encrypt_value(to_bytes)
    end

    def self.encrypt_value(bytes)
      payload = current_encryptor.encrypt_and_sign(Base64.strict_encode64(bytes))
      "#{ENCRYPTION_VERSION}:#{payload}"
    end

    # Re-encrypt a stored ciphertext to the current scheme: decrypt with
    # whatever version it currently is, return a fresh current-version
    # ciphertext. Drives `solana:reencrypt_managed_wallets`.
    def self.reencrypt(encrypted_string)
      from_encrypted(encrypted_string).encrypt
    end

    # True if a ciphertext is already at the current encryption version.
    def self.current_version?(encrypted_string)
      encrypted_string.to_s.start_with?("#{ENCRYPTION_VERSION}:")
    end

    def self.parse_encrypted(s)
      if current_version?(s)
        [ENCRYPTION_VERSION, s.delete_prefix("#{ENCRYPTION_VERSION}:")]
      else
        [:legacy, s]
      end
    end
    private_class_method :parse_encrypted

    def self.encryptor_for(version)
      case version
      when ENCRYPTION_VERSION then current_encryptor
      when :legacy            then legacy_encryptor
      else raise "unknown managed-wallet encryption version: #{version.inspect}"
      end
    end
    private_class_method :encryptor_for

    # Current scheme: 256-bit key derived from MANAGED_WALLET_ENCRYPTION_KEY
    # via KeyGenerator (PBKDF2 + domain-separation label). In production the
    # env var is mandatory — config/initializers/managed_wallet_encryption.rb
    # fails the boot if it's missing. Dev/test/CI fall back to secret_key_base
    # run through the SAME KDF: still a proper 256-bit key, just not
    # rotation-isolated (acceptable off-prod).
    def self.current_encryptor
      @current_encryptor ||= begin
        material = ENV["MANAGED_WALLET_ENCRYPTION_KEY"].presence ||
                   Rails.application.credentials.secret_key_base
        key = ActiveSupport::KeyGenerator.new(material).generate_key("turf-monster managed wallet v2", 32)
        ActiveSupport::MessageEncryptor.new(key)
      end
    end
    private_class_method :current_encryptor

    # Legacy scheme (pre-OPSEC-015): the first 32 CHARS of the hex
    # secret_key_base — only ~128 bits of real entropy. Kept solely so
    # pre-migration ciphertexts still decrypt. Never encrypt new data here.
    def self.legacy_encryptor
      @legacy_encryptor ||= ActiveSupport::MessageEncryptor.new(
        Rails.application.credentials.secret_key_base[0, 32]
      )
    end
    private_class_method :legacy_encryptor
  end
end
