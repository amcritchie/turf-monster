module Solana
  module Config
    PROGRAM_ID = ENV.fetch("SOLANA_PROGRAM_ID", "7Hy8GmJWPMdt6bx3VG4BLFnpNX9TBwkPt87W6bkHgr2J")
    RPC_URL = ENV.fetch("SOLANA_RPC_URL", "https://api.devnet.solana.com")
    NETWORK = ENV.fetch("SOLANA_NETWORK", "devnet")

    # Devnet test mints (created via spl-token create-token --decimals 6)
    USDC_MINT = ENV.fetch("SOLANA_USDC_MINT", "222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9")
    USDT_MINT = ENV.fetch("SOLANA_USDT_MINT", "9mxkN8KaVA8FFgDE2LEsn2UbYLPG8Xg9bf4V9MYYi8Ne")

    # Admin keypair path for signing settlement transactions
    ADMIN_KEYPAIR_PATH = ENV.fetch("SOLANA_ADMIN_KEYPAIR", File.expand_path("~/.config/solana/id.json"))

    # Multisig signers (base58 addresses)
    MULTISIG_SIGNERS = ENV.fetch("SOLANA_MULTISIG_SIGNERS",
      "F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ,7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr,CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR"
    ).split(",")
    MULTISIG_THRESHOLD = ENV.fetch("SOLANA_MULTISIG_THRESHOLD", "2").to_i

    # Default cosigner for partially-signed treasury TXs (Alex Human — signs via Phantom)
    MULTISIG_COSIGNER = ENV.fetch("SOLANA_MULTISIG_COSIGNER", "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr")

    DECIMALS = 6

    # IDL hash pinning (audit Tier 3 #22). Catches drift between the Rails
    # app's expected program shape and what's actually deployed on-chain.
    # Workflow:
    #   1. Operator runs `bin/rails solana:verify_idl` (or `anchor idl fetch`)
    #      to download the deployed IDL into config/turf_vault.idl.json
    #   2. Operator runs `bin/rails solana:idl_hash` to print the SHA256
    #   3. Set EXPECTED_IDL_HASH below (or in env) to that value
    #   4. On every boot (production only), the initializer compares the
    #      committed IDL's hash against EXPECTED_IDL_HASH. Mismatch raises.
    #
    # IDL_PATH points at the committed IDL JSON. The file is hand-maintained
    # — updated when turf_vault deploys a new version.
    IDL_PATH = Rails.root.join("config", "turf_vault.idl.json")

    # Set after each turf_vault deploy. Empty string = skip verification (dev
    # default; set in production env or here after pinning).
    EXPECTED_IDL_HASH = ENV.fetch("EXPECTED_IDL_HASH", "")

    def self.devnet?
      NETWORK == "devnet"
    end

    def self.mainnet?
      NETWORK == "mainnet-beta"
    end

    def self.dollars_to_lamports(dollars)
      (dollars * 10**DECIMALS).to_i
    end

    def self.lamports_to_dollars(lamports)
      lamports.to_f / 10**DECIMALS
    end

    # SHA256 hex digest of the committed IDL file. Returns nil if the file
    # is missing (which is the case until the operator pulls it once).
    def self.idl_hash
      return nil unless File.exist?(IDL_PATH)
      Digest::SHA256.hexdigest(File.read(IDL_PATH))
    end

    # Raises Solana::Config::IdlMismatchError if the committed IDL's hash
    # doesn't match EXPECTED_IDL_HASH. No-op when either side is empty (dev
    # before pinning, missing IDL file).
    def self.verify_idl!
      return if EXPECTED_IDL_HASH.blank?
      actual = idl_hash
      return if actual.nil?  # warn-via-log handled in the boot hook
      return if actual == EXPECTED_IDL_HASH

      raise IdlMismatchError, <<~MSG
        IDL hash mismatch — refusing to boot.

        Expected: #{EXPECTED_IDL_HASH}
        Got:      #{actual}

        Either #{IDL_PATH} drifted from the deployed program, or someone
        tampered with it. Re-pull the IDL with:
          anchor idl fetch #{PROGRAM_ID} --provider.cluster #{NETWORK} \\
            > #{IDL_PATH}
          bin/rails solana:idl_hash  # then set EXPECTED_IDL_HASH

        To bypass temporarily: heroku config:unset EXPECTED_IDL_HASH (or
        unset locally). Don't ship to prod without a pin.
      MSG
    end

    class IdlMismatchError < StandardError; end
  end
end
