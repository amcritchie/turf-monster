module Solana
  module Config
    # OPSEC-012: `SOLANA_PROGRAM_ID` required in production. Previously fell
    # back to the orphaned `7Hy8…r2J` (which we no longer control on devnet
    # and doesn't exist on mainnet). A missing env var would have silently
    # routed every TX to a non-existent program — or worse, to whatever an
    # attacker might deploy at that address on mainnet. Dev/test default to
    # the current devnet program ID; prod must set it explicitly.
    PROGRAM_ID = if Rails.env.production?
      ENV.fetch("SOLANA_PROGRAM_ID") { raise "SOLANA_PROGRAM_ID required in production (see OPSEC-012)" }
    else
      ENV.fetch("SOLANA_PROGRAM_ID", "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ")
    end
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

    # turf-vault v0.15.0+: the ONLY wallet permitted to call `initialize` on
    # mainnet builds (per `state.rs::INIT_AUTHORITY`). Today this is the same
    # key as MULTISIG_COSIGNER (Alex's Phantom), but it's kept separate so a
    # future rotation of either role doesn't silently move the other.
    INIT_AUTHORITY = ENV.fetch("SOLANA_INIT_AUTHORITY", "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr")

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
    #
    # Network-keyed (mainnet launch): the devnet and mainnet IDLs are
    # byte-identical EXCEPT the `address` field (the program ID), which makes
    # their SHA256 differ. Each cluster therefore commits its own IDL file and
    # pins its own EXPECTED_IDL_HASH per Heroku app. Selection is by NETWORK so
    # a single source tree boots correctly on either cluster:
    #   - mainnet-beta -> config/turf_vault.mainnet.idl.json (address mnzow…, 70e8f7…)
    #   - anything else (devnet/localnet) -> config/turf_vault.idl.json (address EQGF…, 99d551…)
    # The devnet branch is byte-identical to the prior unconditional path, so
    # the live devnet-prod app's verify_idl!/precompile behavior is unchanged.
    IDL_PATH = if NETWORK == "mainnet-beta"
      Rails.root.join("config", "turf_vault.mainnet.idl.json")
    else
      Rails.root.join("config", "turf_vault.idl.json")
    end

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
    # doesn't match EXPECTED_IDL_HASH.
    #
    # OPSEC-014: in production, BOTH EXPECTED_IDL_HASH being set AND the IDL
    # file being present are required — fails closed. In dev/test we still
    # short-circuit on blank/missing because local iteration is allowed
    # against an older IDL.
    def self.verify_idl!
      # OPSEC-014 emergency bypass. Lets ops break out of a deploy-time IDL
      # skew (e.g. when EXPECTED_IDL_HASH, the committed IDL file, and the
      # freshly-built IDL have all diverged across turf-vault versions).
      # Set BYPASS_IDL_CHECK=true on Heroku, deploy the new IDL, then run
      # `heroku config:set EXPECTED_IDL_HASH=<new>` + `heroku config:unset
      # BYPASS_IDL_CHECK` to restore verified state. Logs loud so the
      # unverified window is visible in production logs.
      if ENV["BYPASS_IDL_CHECK"].to_s.downcase == "true"
        Rails.logger.warn "[opsec-014] IDL verification BYPASSED via BYPASS_IDL_CHECK=true — production is running unverified. Unset BYPASS_IDL_CHECK after the next successful release."
        return
      end

      if EXPECTED_IDL_HASH.blank?
        raise IdlMismatchError, "EXPECTED_IDL_HASH required in production (see OPSEC-014)" if Rails.env.production?
        return
      end

      actual = idl_hash
      if actual.nil?
        raise IdlMismatchError, "#{IDL_PATH} not found — IDL must be committed in production (see OPSEC-014)" if Rails.env.production?
        return
      end

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

        To bypass during a deploy (production): `heroku config:set
        BYPASS_IDL_CHECK=true`, deploy, then `heroku config:set
        EXPECTED_IDL_HASH=<new>` + `heroku config:unset BYPASS_IDL_CHECK`
        to restore verified state. Don't leave BYPASS on.
        In dev/test: `unset EXPECTED_IDL_HASH`. Don't ship to prod without a pin.
      MSG
    end

    class IdlMismatchError < StandardError; end
  end
end
