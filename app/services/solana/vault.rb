require "digest"

module Solana
  class Vault
    attr_reader :client

    def initialize(client: Solana::Client.new)
      @client = client
      @program_id = Keypair.decode_base58(Config::PROGRAM_ID)
    end

    # --- PDA helpers ---

    def vault_state_pda
      Transaction.find_pda([b("vault")], @program_id)
    end

    def vault_usdc_pda
      Transaction.find_pda([b("vault_usdc")], @program_id)
    end

    def vault_usdt_pda
      Transaction.find_pda([b("vault_usdt")], @program_id)
    end

    def user_account_pda(wallet_address)
      wallet_bytes = Keypair.decode_base58(wallet_address)
      Transaction.find_pda([b("user"), wallet_bytes], @program_id)
    end

    def contest_pda(contest_slug)
      contest_id = Digest::SHA256.digest(contest_slug)
      Transaction.find_pda([b("contest"), contest_id], @program_id)
    end

    def entry_pda(contest_slug, wallet_address, entry_num)
      contest_id = Digest::SHA256.digest(contest_slug)
      wallet_bytes = Keypair.decode_base58(wallet_address)
      entry_num_bytes = [entry_num].pack("V") # u32 LE
      Transaction.find_pda([b("entry"), contest_id, wallet_bytes, entry_num_bytes], @program_id)
    end

    def entry_token_pda(wallet_address, sequence)
      wallet_bytes = Keypair.decode_base58(wallet_address)
      seq_bytes = [sequence].pack("Q<") # u64 LE — matches Anchor's `sequence.to_le_bytes()`
      Transaction.find_pda([b("entry_token"), wallet_bytes, seq_bytes], @program_id)
    end

    def season_pda(season_id)
      id_bytes = [season_id].pack("V") # u32 LE — matches Anchor's `season_id.to_le_bytes()`
      Transaction.find_pda([b("season"), id_bytes], @program_id)
    end

    # --- ATA helpers ---

    def admin_usdc_ata
      admin = Keypair.admin
      Solana::SplToken.find_associated_token_address(admin.public_key_bytes, Config::USDC_MINT)
    end

    # Ensure an ATA exists for wallet + mint. Creates it if missing.
    # Returns { ata: base58, created: bool, signature: string|nil }
    def ensure_ata(wallet_address, mint:)
      ata_bytes, _ = Solana::SplToken.find_associated_token_address(wallet_address, mint)
      ata_base58 = Keypair.encode_base58(ata_bytes)

      info = client.get_account_info(ata_base58)
      if info&.dig("value")
        return { ata: ata_base58, created: false, signature: nil }
      end

      admin = Keypair.admin
      create_ix = Solana::SplToken.create_associated_token_account_instruction(
        payer: admin.public_key_bytes,
        wallet: wallet_address,
        mint: mint
      )

      tx = build_tx(admin)
      tx.add_instruction(**create_ix)
      signature = client.send_and_confirm(tx.serialize_base64)

      { ata: ata_base58, created: true, signature: signature }
    rescue Solana::Client::RpcError => e
      # ATA may have been created concurrently (e.g. by EnsureAtaJob).
      # Re-check and return if it now exists; otherwise re-raise.
      raise unless e.message.include?("IllegalOwner")
      info = client.get_account_info(ata_base58)
      raise unless info&.dig("value")
      { ata: ata_base58, created: false, signature: nil }
    end

    # Mint SPL tokens (admin must be mint authority). Defaults to admin's ATA.
    def mint_spl(amount_lamports, mint:, to: nil)
      admin = Keypair.admin

      if to
        dest_bytes, _ = Solana::SplToken.find_associated_token_address(to, mint)
      else
        dest_bytes, _ = admin_usdc_ata
      end

      mint_ix = Solana::SplToken.mint_to_instruction(
        mint: mint,
        destination: dest_bytes,
        authority: admin.public_key_bytes,
        amount: amount_lamports
      )

      tx = build_tx(admin)
      tx.add_instruction(**mint_ix)
      signature = client.send_and_confirm(tx.serialize_base64)

      { signature: signature, amount: amount_lamports, destination: Keypair.encode_base58(dest_bytes) }
    end

    # Transfer SPL tokens from admin's ATA to a recipient wallet's ATA.
    # Ensures recipient ATA exists first.
    def transfer_spl(to_wallet, amount_lamports, mint:)
      admin = Keypair.admin

      # Ensure recipient ATA exists
      ensure_ata(to_wallet, mint: mint)

      from_bytes, _ = Solana::SplToken.find_associated_token_address(admin.public_key_bytes, mint)
      to_bytes, _ = Solana::SplToken.find_associated_token_address(to_wallet, mint)

      transfer_ix = Solana::SplToken.transfer_instruction(
        from: from_bytes, to: to_bytes,
        authority: admin.public_key_bytes, amount: amount_lamports
      )

      tx = build_tx(admin)
      tx.add_instruction(**transfer_ix)
      signature = client.send_and_confirm(tx.serialize_base64)

      { signature: signature, amount: amount_lamports, destination: Keypair.encode_base58(to_bytes) }
    end

    # Transfer USDC from a user's managed wallet to the admin wallet.
    # Server signs with the user's keypair. Used for entry fee payments.
    def transfer_from_user(user, amount_lamports, mint:)
      keypair = user.solana_keypair
      raise "No managed wallet key" unless keypair

      admin = Keypair.admin
      from_pubkey = keypair.public_key_bytes
      to_pubkey = admin.public_key_bytes

      ensure_ata(Keypair.encode_base58(from_pubkey), mint: mint)
      ensure_ata(Keypair.encode_base58(to_pubkey), mint: mint)

      from_ata, _ = Solana::SplToken.find_associated_token_address(from_pubkey, mint)
      to_ata, _ = Solana::SplToken.find_associated_token_address(to_pubkey, mint)

      transfer_ix = Solana::SplToken.transfer_instruction(
        from: from_ata, to: to_ata,
        authority: from_pubkey, amount: amount_lamports
      )

      tx = build_tx(admin)    # admin pays SOL fees
      tx.add_signer(keypair)  # user authorizes the token transfer
      tx.add_instruction(**transfer_ix)
      signature = client.send_and_confirm(tx.serialize_base64)

      { signature: signature, amount: amount_lamports }
    end

    # --- High-level operations ---

    # Initialize the vault (run once after program deploy)
    # signers: array of 3 base58 signer addresses
    # threshold: number of required signatures for treasury ops
    def initialize_vault(signers:, threshold:)
      admin = Keypair.admin
      vault_pda, _ = vault_state_pda
      usdc_mint = Keypair.decode_base58(Config::USDC_MINT)
      usdt_mint = Keypair.decode_base58(Config::USDT_MINT)
      vault_usdc, _ = vault_usdc_pda
      vault_usdt, _ = vault_usdt_pda

      data = Transaction.anchor_discriminator("initialize") +
             signers.map { |s| Borsh.encode_pubkey(Keypair.decode_base58(s)) }.join +
             Borsh.encode_u8(threshold)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: vault_pda, is_signer: false, is_writable: true },
          { pubkey: usdc_mint, is_signer: false, is_writable: false },
          { pubkey: usdt_mint, is_signer: false, is_writable: false },
          { pubkey: vault_usdc, is_signer: false, is_writable: true },
          { pubkey: vault_usdt, is_signer: false, is_writable: true },
          { pubkey: Transaction::TOKEN_PROGRAM_ID, is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSVAR_RENT_PUBKEY, is_signer: false, is_writable: false }
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature, vault_pda: Keypair.encode_base58(vault_pda) }
    end

    # Force-close the vault account (migration only — closes old-schema vault)
    # Requires 2-of-3 multisig: cosigner_keypair must be a second signer
    def force_close_vault(cosigner_keypair: nil)
      admin = Keypair.admin
      vault_pda, _ = vault_state_pda

      data = Transaction.anchor_discriminator("force_close_vault")

      accounts = [
        { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
      ]

      # Add cosigner if provided (multisig vault), otherwise single-admin (legacy)
      if cosigner_keypair
        accounts << { pubkey: cosigner_keypair.public_key_bytes, is_signer: true, is_writable: false }
      end

      accounts << { pubkey: vault_pda, is_signer: false, is_writable: true }

      tx = build_tx(admin)
      tx.add_signer(cosigner_keypair) if cosigner_keypair
      tx.add_instruction(
        program_id: @program_id,
        accounts: accounts,
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature }
    end

    # Check status of a UserAccount PDA: :ok, :needs_migration, or :not_found
    def check_user_account_status(wallet_address)
      user_pda, _ = user_account_pda(wallet_address)
      info = client.get_account_info(Keypair.encode_base58(user_pda))
      return :not_found unless info&.dig("value")

      data = Base64.decode64(info["value"]["data"][0])
      expected_len = 81 # 8 discriminator + 73 UserAccount fields (v0.5.0+)
      data.length == expected_len ? :ok : :needs_migration
    end

    # Ensure user's onchain account exists and is current, create or migrate as needed
    def ensure_user_account(wallet_address)
      status = check_user_account_status(wallet_address)
      case status
      when :ok then nil
      when :needs_migration then migrate_user_account(wallet_address)
      when :not_found then create_user_account(wallet_address)
      end
    end

    # Migrate a UserAccount PDA to the current struct size (admin-only, idempotent)
    def migrate_user_account(wallet_address)
      admin = Keypair.admin
      vault_pda, _ = vault_state_pda
      user_pda, _ = user_account_pda(wallet_address)
      wallet_bytes = Keypair.decode_base58(wallet_address)

      data = Transaction.anchor_discriminator("migrate_user_account")

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: vault_pda, is_signer: false, is_writable: false },
          { pubkey: user_pda, is_signer: false, is_writable: true },
          { pubkey: wallet_bytes, is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature, pda: Keypair.encode_base58(user_pda) }
    end

    # Create a UserAccount PDA for a wallet (admin pays rent)
    def create_user_account(wallet_address)
      admin = Keypair.admin
      user_pda, _bump = user_account_pda(wallet_address)
      wallet_bytes = Keypair.decode_base58(wallet_address)

      data = Transaction.anchor_discriminator("create_user_account") +
             Borsh.encode_pubkey(wallet_bytes)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: user_pda, is_signer: false, is_writable: true },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature, pda: Keypair.encode_base58(user_pda) }
    end

    # Fund a user's wallet ATA with USDC.
    # Devnet: mints new tokens (admin has mint authority).
    # Mainnet: would transfer from treasury.
    def fund_user(wallet_address, amount_lamports, mint: :usdc)
      mint_key = mint == :usdc ? Config::USDC_MINT : Config::USDT_MINT
      ensure_ata(wallet_address, mint: mint_key)

      if Config.devnet?
        mint_spl(amount_lamports, mint: mint_key, to: wallet_address)
      else
        transfer_spl(wallet_address, amount_lamports, mint: mint_key)
      end
    end

    # Withdraw from vault back to user's ATA (server signs with managed wallet keypair)
    def withdraw(user_keypair, amount_lamports, mint: :usdc)
      admin = Keypair.admin
      wallet_address = user_keypair.to_base58
      user_pda, _ = user_account_pda(wallet_address)
      vault_pda, _ = vault_state_pda
      vault_token_pda, _ = mint == :usdc ? vault_usdc_pda : vault_usdt_pda
      mint_pubkey = mint == :usdc ? Config::USDC_MINT : Config::USDT_MINT

      user_ata, _ = Solana::SplToken.find_associated_token_address(wallet_address, mint_pubkey)

      data = Transaction.anchor_discriminator("withdraw") +
             Borsh.encode_u64(amount_lamports)

      tx = build_tx(user_keypair)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: user_keypair.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: user_pda, is_signer: false, is_writable: true },
          { pubkey: vault_pda, is_signer: false, is_writable: false },
          { pubkey: Keypair.decode_base58(mint_pubkey), is_signer: false, is_writable: false },
          { pubkey: user_ata, is_signer: false, is_writable: true },
          { pubkey: vault_token_pda, is_signer: false, is_writable: true },
          { pubkey: Transaction::TOKEN_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      client.send_and_confirm(tx.serialize_base64)
    end

    # Deposit for managed wallet users (server signs with their keypair)
    def deposit(user_keypair, amount_lamports, mint: :usdc)
      admin = Keypair.admin
      wallet_address = user_keypair.to_base58
      user_pda, _ = user_account_pda(wallet_address)
      vault_pda, _ = vault_state_pda
      vault_token_pda, _ = mint == :usdc ? vault_usdc_pda : vault_usdt_pda
      mint_pubkey = mint == :usdc ? Config::USDC_MINT : Config::USDT_MINT

      user_ata, _ = Solana::SplToken.find_associated_token_address(wallet_address, mint_pubkey)

      data = Transaction.anchor_discriminator("deposit") +
             Borsh.encode_u64(amount_lamports)

      # For managed: user_keypair signs, admin pays fees
      tx = build_tx(user_keypair)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: user_keypair.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: user_pda, is_signer: false, is_writable: true },
          { pubkey: vault_pda, is_signer: false, is_writable: false },
          { pubkey: Keypair.decode_base58(mint_pubkey), is_signer: false, is_writable: false },
          { pubkey: user_ata, is_signer: false, is_writable: true },
          { pubkey: vault_token_pda, is_signer: false, is_writable: true },
          { pubkey: Transaction::TOKEN_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      client.send_and_confirm(tx.serialize_base64)
    end

    # Build a partially-signed create_contest transaction.
    # Admin signs (pays PDA rent), creator must sign client-side (authorizes prizes USDC transfer).
    # Returns base64-encoded transaction for the creator to co-sign and submit.
    def build_create_contest(wallet_address, contest_slug, entry_fee:, max_entries:, payout_amounts:, prizes:, season_id: nil)
      admin = Keypair.admin
      wallet_bytes = Keypair.decode_base58(wallet_address)
      contest_id = Digest::SHA256.digest(contest_slug)
      contest_pda_addr, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda

      usdc_mint = Keypair.decode_base58(Config::USDC_MINT)
      creator_ata, _ = Solana::SplToken.find_associated_token_address(wallet_address, Config::USDC_MINT)
      vault_usdc, _ = vault_usdc_pda

      # OPSEC-023: create_contest now records the season the contest is bound to.
      season_id ||= SeasonConfig.current_season_id

      data = Transaction.anchor_discriminator("create_contest") +
             Borsh.encode_bytes32(contest_id) +
             Borsh.encode_u32(season_id) +
             Borsh.encode_u64(entry_fee) +
             Borsh.encode_u32(max_entries) +
             Borsh.encode_vec(payout_amounts) { |amt| Borsh.encode_u64(amt) } +
             Borsh.encode_u64(prizes)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },   # payer
          { pubkey: wallet_bytes, is_signer: true, is_writable: true },              # creator (signs USDC transfer)
          { pubkey: vault_pda, is_signer: false, is_writable: false },               # vault_state
          { pubkey: contest_pda_addr, is_signer: false, is_writable: true },         # contest (init)
          { pubkey: usdc_mint, is_signer: false, is_writable: false },               # mint
          { pubkey: creator_ata, is_signer: false, is_writable: true },              # creator_token_account
          { pubkey: vault_usdc, is_signer: false, is_writable: true },               # vault_token_account
          { pubkey: Transaction::TOKEN_PROGRAM_ID, is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      # Partial sign: admin signs, creator's signature slot left as zeros
      serialized = tx.serialize_partial_base64(additional_signers: [wallet_bytes])
      contest_pda_b58 = Keypair.encode_base58(contest_pda_addr)

      { serialized_tx: serialized, contest_pda: contest_pda_b58 }
    end

    # Server-funded `create_contest` — admin signs as BOTH payer AND creator.
    # The Anchor program dedupes signers by pubkey so the single admin sig
    # covers both required signatures. Prize-pool USDC is transferred from
    # the admin's own ATA into the vault PDA.
    #
    # Use this for operator-run contests (no human creator). For contests
    # where a different human funds the prize pool from their Phantom wallet,
    # use `build_create_contest` + the partial-sign / co-sign UI flow instead.
    #
    # Submits the TX synchronously and waits for confirmation.
    # Returns { tx_signature:, contest_pda: } (both base58 strings).
    def create_contest_server_funded(contest_slug:, entry_fee:, max_entries:, payout_amounts:, prizes:, season_id: nil)
      admin = Keypair.admin
      contest_id = Digest::SHA256.digest(contest_slug)
      contest_pda_addr, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda

      usdc_mint = Keypair.decode_base58(Config::USDC_MINT)
      admin_b58 = Keypair.encode_base58(admin.public_key_bytes)
      creator_ata, _ = Solana::SplToken.find_associated_token_address(admin_b58, Config::USDC_MINT)
      vault_usdc, _ = vault_usdc_pda

      # OPSEC-023: create_contest now records the season the contest is bound to.
      season_id ||= SeasonConfig.current_season_id

      data = Transaction.anchor_discriminator("create_contest") +
             Borsh.encode_bytes32(contest_id) +
             Borsh.encode_u32(season_id) +
             Borsh.encode_u64(entry_fee) +
             Borsh.encode_u32(max_entries) +
             Borsh.encode_vec(payout_amounts) { |amt| Borsh.encode_u64(amt) } +
             Borsh.encode_u64(prizes)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },   # payer
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },   # creator (= admin; dedup'd by Solana)
          { pubkey: vault_pda, is_signer: false, is_writable: false },              # vault_state
          { pubkey: contest_pda_addr, is_signer: false, is_writable: true },        # contest (init)
          { pubkey: usdc_mint, is_signer: false, is_writable: false },              # mint
          { pubkey: creator_ata, is_signer: false, is_writable: true },             # creator_token_account (admin's ATA)
          { pubkey: vault_usdc, is_signer: false, is_writable: true },              # vault_token_account
          { pubkey: Transaction::TOKEN_PROGRAM_ID, is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      serialized = tx.serialize_base64
      tx_sig = client.send_transaction(serialized)
      # Wait for finalization so callers can immediately use the contest_pda.
      deadline = Time.now + 30
      loop do
        sleep 1
        status = client.confirm_transaction(tx_sig).dig("value", 0)
        if status
          raise "create_contest TX failed: #{status["err"]}" if status["err"]
          break if %w[confirmed finalized].include?(status["confirmationStatus"])
        end
        raise "create_contest TX confirmation timeout (sig=#{tx_sig})" if Time.now > deadline
      end

      contest_pda_b58 = Keypair.encode_base58(contest_pda_addr)
      { tx_signature: tx_sig, contest_pda: contest_pda_b58 }
    end

    # Enter contest (admin signs, deducts from user balance onchain).
    # `season_id` defaults to SeasonConfig.current_season_id — the active season's
    # seed_schedule drives how many seeds are awarded.
    def enter_contest(wallet_address, contest_slug, entry_num, season_id: nil)
      admin = Keypair.admin
      contest_id = Digest::SHA256.digest(contest_slug)
      wallet_bytes = Keypair.decode_base58(wallet_address)
      vault_pda, _ = vault_state_pda
      user_pda, _ = user_account_pda(wallet_address)
      c_pda, _ = contest_pda(contest_slug)
      e_pda, _ = entry_pda(contest_slug, wallet_address, entry_num)
      season_id ||= SeasonConfig.current_season_id
      s_pda, _ = season_pda(season_id)

      data = Transaction.anchor_discriminator("enter_contest") +
             Borsh.encode_u32(entry_num)

      # First-time entrant's UserAccount may have just been created — retry if
      # its PDA hasn't reached the preflight node yet (Anchor 3012 / 0xbc4).
      signature = with_account_init_retry do
        tx = build_tx(admin)
        tx.add_instruction(
          program_id: @program_id,
          accounts: [
            { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
            { pubkey: wallet_bytes, is_signer: false, is_writable: false },
            { pubkey: vault_pda, is_signer: false, is_writable: false },
            { pubkey: user_pda, is_signer: false, is_writable: true },
            { pubkey: c_pda, is_signer: false, is_writable: true },
            { pubkey: e_pda, is_signer: false, is_writable: true },
            { pubkey: s_pda, is_signer: false, is_writable: false },
            { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
          ],
          data: data
        )
        client.send_and_confirm(tx.serialize_base64)
      end
      { signature: signature, entry_pda: Keypair.encode_base58(e_pda) }
    end

    # Enter contest using an unconsumed on-chain entry token (turf-vault v0.10.0+).
    # Atomic: creates the entry, consumes the token, awards seeds per the season's
    # seed_schedule[entry_num.min(4)]. No USDC charged.
    # `entry_token_pda_b58` is the base58 PDA of the EntryTokenAccount being consumed.
    # OPSEC-004: `user_keypair` is now required — turf-vault v0.12.0 makes the
    # `wallet` account a Signer on enter_contest_with_token. For managed (web2)
    # wallets the server holds the custodial keypair and co-signs; this means a
    # leaked admin key alone can no longer burn a user's entry token.
    def enter_contest_with_token(wallet_address, contest_slug, entry_num, entry_token_pda_b58, user_keypair:, season_id: nil)
      raise "user_keypair required (OPSEC-004)" unless user_keypair
      admin = Keypair.admin
      wallet_bytes = Keypair.decode_base58(wallet_address)
      vault_pda, _ = vault_state_pda
      user_pda, _ = user_account_pda(wallet_address)
      c_pda, _ = contest_pda(contest_slug)
      e_pda, _ = entry_pda(contest_slug, wallet_address, entry_num)
      token_pda_bytes = Keypair.decode_base58(entry_token_pda_b58)
      season_id ||= SeasonConfig.current_season_id
      s_pda, _ = season_pda(season_id)

      data = Transaction.anchor_discriminator("enter_contest_with_token") +
             Borsh.encode_u32(entry_num)

      # See enter_contest — same first-entry UserAccount propagation race.
      signature = with_account_init_retry do
        tx = build_tx(admin)
        tx.add_signer(user_keypair)  # OPSEC-004: server co-signs as the managed user
        tx.add_instruction(
          program_id: @program_id,
          accounts: [
            { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
            { pubkey: wallet_bytes, is_signer: true, is_writable: false },
            { pubkey: vault_pda, is_signer: false, is_writable: false },
            { pubkey: user_pda, is_signer: false, is_writable: true },
            { pubkey: c_pda, is_signer: false, is_writable: true },
            { pubkey: e_pda, is_signer: false, is_writable: true },
            { pubkey: token_pda_bytes, is_signer: false, is_writable: true },
            { pubkey: s_pda, is_signer: false, is_writable: false },
            { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
          ],
          data: data
        )
        client.send_and_confirm(tx.serialize_base64)
      end
      invalidate_entry_tokens_cache(wallet_address)
      { signature: signature, entry_pda: Keypair.encode_base58(e_pda) }
    end

    # Build a partially-signed enter_contest_direct transaction.
    # Admin signs (pays rent), user must sign client-side (authorizes USDC transfer).
    # Returns base64-encoded transaction for the client to co-sign and submit.
    def build_enter_contest_direct(wallet_address, contest_slug, entry_num, season_id: nil)
      admin = Keypair.admin
      wallet_bytes = Keypair.decode_base58(wallet_address)
      user_pda, _ = user_account_pda(wallet_address)
      vault_pda, _ = vault_state_pda
      c_pda, _ = contest_pda(contest_slug)
      e_pda, _ = entry_pda(contest_slug, wallet_address, entry_num)

      usdc_mint = Keypair.decode_base58(Config::USDC_MINT)
      user_ata, _ = Solana::SplToken.find_associated_token_address(wallet_address, Config::USDC_MINT)
      vault_usdc, _ = vault_usdc_pda

      # Season PDA — v0.11.0+ enter_contest_direct reads seed_schedule from it
      season_id ||= SeasonConfig.current_season_id
      s_pda, _ = season_pda(season_id)

      data = Transaction.anchor_discriminator("enter_contest_direct") +
             Borsh.encode_u32(entry_num)

      tx = build_tx(admin)  # admin is fee payer and first signer
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },   # payer
          { pubkey: wallet_bytes, is_signer: true, is_writable: true },              # user (signs token transfer)
          { pubkey: user_pda, is_signer: false, is_writable: true },                 # user_account (seeds awarded)
          { pubkey: vault_pda, is_signer: false, is_writable: false },               # vault_state
          { pubkey: c_pda, is_signer: false, is_writable: true },                    # contest
          { pubkey: e_pda, is_signer: false, is_writable: true },                    # contest_entry (init)
          { pubkey: usdc_mint, is_signer: false, is_writable: false },               # mint
          { pubkey: user_ata, is_signer: false, is_writable: true },                 # user_token_account
          { pubkey: vault_usdc, is_signer: false, is_writable: true },               # vault_token_account
          { pubkey: Transaction::TOKEN_PROGRAM_ID, is_signer: false, is_writable: false },
          { pubkey: s_pda, is_signer: false, is_writable: false },                   # season (seed_schedule)
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      # Partial sign: admin signs, user's signature slot left as zeros
      serialized = tx.serialize_partial_base64(additional_signers: [wallet_bytes])
      entry_pda_b58 = Keypair.encode_base58(e_pda)

      { serialized_tx: serialized, entry_pda: entry_pda_b58 }
    end

    # Settle contest — requires 2-of-3 multisig (admin + cosigner_keypair)
    # Used in rake tasks / E2E tests where server has both keys.
    def settle_contest(contest_slug, settlements, cosigner_keypair: nil)
      admin = Keypair.admin
      cosigner = cosigner_keypair || admin  # fallback for tests
      c_pda, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda

      # Build settlement data
      settlement_data = settlements.map do |s|
        Borsh.encode_pubkey(Keypair.decode_base58(s[:wallet])) +
        Borsh.encode_u32(s[:entry_num]) +
        Borsh.encode_u32(s[:rank]) +
        Borsh.encode_u64(s[:payout])
      end

      data = Transaction.anchor_discriminator("settle_contest") +
             Borsh.encode_u32(settlements.length) +
             settlement_data.join

      # Build remaining accounts (pairs of user_account + contest_entry)
      remaining = settlements.flat_map do |s|
        user_pda, _ = user_account_pda(s[:wallet])
        e_pda, _ = entry_pda(contest_slug, s[:wallet], s[:entry_num])
        [
          { pubkey: user_pda, is_signer: false, is_writable: true },
          { pubkey: e_pda, is_signer: false, is_writable: true }
        ]
      end

      tx = build_tx(admin)
      tx.add_signer(cosigner) if cosigner != admin
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: cosigner.public_key_bytes, is_signer: true, is_writable: false },
          { pubkey: vault_pda, is_signer: false, is_writable: false },
          { pubkey: c_pda, is_signer: false, is_writable: true }
        ] + remaining,
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature }
    end

    # Build a partially-signed settle_contest transaction for multisig cosigning.
    # Admin signs, cosigner_pubkey slot left empty for client-side signing.
    # Returns base64-encoded partially-signed TX.
    def build_settle_contest(contest_slug, settlements, cosigner_pubkey:)
      admin = Keypair.admin
      c_pda, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda
      cosigner_bytes = Keypair.decode_base58(cosigner_pubkey)

      # Build settlement data
      settlement_data = settlements.map do |s|
        Borsh.encode_pubkey(Keypair.decode_base58(s[:wallet])) +
        Borsh.encode_u32(s[:entry_num]) +
        Borsh.encode_u32(s[:rank]) +
        Borsh.encode_u64(s[:payout])
      end

      data = Transaction.anchor_discriminator("settle_contest") +
             Borsh.encode_u32(settlements.length) +
             settlement_data.join

      # Build remaining accounts (pairs of user_account + contest_entry)
      remaining = settlements.flat_map do |s|
        user_pda, _ = user_account_pda(s[:wallet])
        e_pda, _ = entry_pda(contest_slug, s[:wallet], s[:entry_num])
        [
          { pubkey: user_pda, is_signer: false, is_writable: true },
          { pubkey: e_pda, is_signer: false, is_writable: true }
        ]
      end

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: cosigner_bytes, is_signer: true, is_writable: false },
          { pubkey: vault_pda, is_signer: false, is_writable: false },
          { pubkey: c_pda, is_signer: false, is_writable: true }
        ] + remaining,
        data: data
      )

      # Partial sign: admin signs, cosigner's signature slot left as zeros
      serialized = tx.serialize_partial_base64(additional_signers: [cosigner_bytes])
      { serialized_tx: serialized, contest_slug: contest_slug }
    end

    # Read onchain Contest account
    def read_contest(contest_slug, commitment: "confirmed")
      pda, _ = contest_pda(contest_slug)
      pda_base58 = Keypair.encode_base58(pda)

      info = client.get_account_info(pda_base58, commitment: commitment)
      return nil unless info&.dig("value")

      data = Base64.decode64(info["value"]["data"][0])
      offset = 8 # skip Anchor discriminator

      _contest_id, offset = Borsh.decode_pubkey(data, offset) # [u8; 32] same size as pubkey
      prizes, offset = Borsh.decode_u64(data, offset)
      entry_fee, offset = Borsh.decode_u64(data, offset)
      entry_fees, offset = Borsh.decode_u64(data, offset)
      max_entries, offset = Borsh.decode_u32(data, offset)
      current_entries, offset = Borsh.decode_u32(data, offset)
      status_byte, offset = Borsh.decode_u8(data, offset)
      # Vec<u64> payout_amounts
      vec_len, offset = Borsh.decode_u32(data, offset)
      payout_amounts = vec_len.times.map { |_| v, offset = Borsh.decode_u64(data, offset); v }
      admin_bytes, offset = Borsh.decode_pubkey(data, offset)
      creator_bytes, offset = Borsh.decode_pubkey(data, offset)

      status_name = %w[Open Locked Settled][status_byte] || "Unknown"

      {
        pda: pda_base58,
        entry_fee: entry_fee,
        entry_fee_dollars: Config.lamports_to_dollars(entry_fee),
        max_entries: max_entries,
        current_entries: current_entries,
        entry_fees: entry_fees,
        entry_fees_dollars: Config.lamports_to_dollars(entry_fees),
        prizes: prizes,
        prizes_dollars: Config.lamports_to_dollars(prizes),
        status: status_name,
        payout_amounts: payout_amounts.map { |a| Config.lamports_to_dollars(a) },
        admin: Keypair.encode_base58(admin_bytes),
        creator: Keypair.encode_base58(creator_bytes)
      }
    end

    # Read onchain UserAccount balance. Handles both old (73-byte) and new (81-byte) layouts.
    def sync_balance(wallet_address, commitment: "confirmed")
      user_pda, _ = user_account_pda(wallet_address)
      pda_base58 = Keypair.encode_base58(user_pda)

      info = client.get_account_info(pda_base58, commitment: commitment)
      return nil unless info&.dig("value")

      account_data = Base64.decode64(info["value"]["data"][0])
      # Skip 8-byte discriminator
      offset = 8
      _wallet, offset = Borsh.decode_pubkey(account_data, offset)
      balance, offset = Borsh.decode_u64(account_data, offset)
      total_deposited, offset = Borsh.decode_u64(account_data, offset)
      total_withdrawn, offset = Borsh.decode_u64(account_data, offset)
      total_won, offset = Borsh.decode_u64(account_data, offset)

      # Seeds field added in v0.5.0 — old accounts (73 bytes) don't have it
      seeds = if account_data.length >= 81
        val, _ = Borsh.decode_u64(account_data, offset)
        val
      else
        0
      end

      {
        balance: balance,
        total_deposited: total_deposited,
        total_withdrawn: total_withdrawn,
        total_won: total_won,
        seeds: seeds,
        balance_dollars: Config.lamports_to_dollars(balance)
      }
    end

    # ── Entry tokens (turf-vault v0.9.0+) ────────────────────────────────────
    # On-chain EntryTokenAccount PDAs per token. Source enum: 0=operator, 1=stripe, 2=moonpay.

    ENTRY_TOKEN_SOURCE = { operator: 0, stripe: 1, moonpay: 2 }.freeze
    ENTRY_TOKEN_LEN = 124 # bytes — 8 disc + 32 owner + 1 source + 64 source_ref + 1 consumed + 9 consumed_at + 8 created_at + 1 bump

    # Admin mints an EntryTokenAccount for `wallet_address`. Auto-picks the next sequence
    # if not supplied. source: symbol or u8; source_ref: arbitrary string, padded/truncated to 64 bytes.
    def mint_entry_token(wallet_address:, source:, source_ref:, sequence: nil)
      sequence ||= next_entry_token_sequence(wallet_address)
      source_u8 = source.is_a?(Symbol) ? ENTRY_TOKEN_SOURCE.fetch(source) : source.to_i

      admin = Keypair.admin
      pda, _ = entry_token_pda(wallet_address, sequence)
      wallet_bytes = Keypair.decode_base58(wallet_address)

      # Pad/truncate source_ref to exactly 64 bytes
      ref_bytes = source_ref.to_s.b.bytes.first(64)
      ref_bytes += [0] * (64 - ref_bytes.length)

      data = Transaction.anchor_discriminator("mint_entry_token") +
             Borsh.encode_u64(sequence) +
             [source_u8].pack("C") +
             ref_bytes.pack("C*")

      vault_pda, _ = vault_state_pda

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        # Order must match MintEntryToken<'info> in
        # turf-vault/programs/turf_vault/src/instructions/mint_entry_token.rs.
        accounts: [
          { pubkey: admin.public_key_bytes,        is_signer: true,  is_writable: true  }, # admin (Signer, mut)
          { pubkey: vault_pda,                     is_signer: false, is_writable: false }, # vault_state (Account<VaultState>)
          { pubkey: wallet_bytes,                  is_signer: false, is_writable: false }, # user_wallet (Unchecked)
          { pubkey: pda,                           is_signer: false, is_writable: true  }, # entry_token (init)
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false } # system_program
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      invalidate_entry_tokens_cache(wallet_address)
      { signature: signature, pda: Keypair.encode_base58(pda), sequence: sequence }
    end

    # List all on-chain EntryTokenAccounts owned by `wallet_address`. 60s cache.
    # Returns array of hashes: { pda, owner, source, source_ref, consumed, consumed_at, created_at }.
    def list_entry_tokens(wallet_address, commitment: "confirmed")
      Rails.cache.fetch(entry_tokens_cache_key(wallet_address), expires_in: 60.seconds) do
        owner_b58 = wallet_address
        program_id_b58 = Keypair.encode_base58(@program_id)
        # `getProgramAccounts` isn't wrapped in solana-studio yet — bridge via the
        # private JSON-RPC call. Remove this `send` once `get_program_accounts` is
        # added to the gem's public API.
        result = client.send(:call, "getProgramAccounts", [
          program_id_b58,
          {
            encoding: "base64",
            commitment: commitment,
            filters: [
              { dataSize: ENTRY_TOKEN_LEN },
              { memcmp: { offset: 8, bytes: owner_b58 } }
            ]
          }
        ])
        (result || []).map { |account| decode_entry_token(account) }
      end
    end

    # Next sequence number = current count of tokens for this user.
    def next_entry_token_sequence(wallet_address)
      list_entry_tokens(wallet_address).length
    end

    def invalidate_entry_tokens_cache(wallet_address)
      Rails.cache.delete(entry_tokens_cache_key(wallet_address))
    end

    def entry_tokens_cache_key(wallet_address)
      "entry_tokens:#{wallet_address}"
    end

    # ── Seasons (turf-vault v0.11.0+) ────────────────────────────────────────
    # On-chain Season PDAs hold the per-season seed schedule that entry instructions
    # use to award seeds (replaces the old hardcoded +65).

    SEASON_LEN = 101 # bytes — 8 disc + 4 season_id + 32 name + 40 schedule + 8 start_at + 8 created_at + 1 bump
    SEASON_DEFAULT_SCHEDULE = [25, 19, 14, 10, 7].freeze

    # Admin creates an on-chain Season. `schedule` must be a 5-element array of u64.
    # `name` is truncated/padded to 32 bytes. `start_at` defaults to now.
    def create_season(season_id:, name:, schedule:, start_at: nil)
      raise ArgumentError, "schedule must have 5 elements" unless schedule.is_a?(Array) && schedule.length == 5
      schedule.each { |v| raise ArgumentError, "schedule values must be non-negative" if v.to_i.negative? }

      start_at ||= Time.current.to_i
      admin = Keypair.admin
      pda, _ = season_pda(season_id)
      vault_pda, _ = vault_state_pda

      name_bytes = name.to_s.b.bytes.first(32)
      name_bytes += [0] * (32 - name_bytes.length)

      data = Transaction.anchor_discriminator("create_season") +
             Borsh.encode_u32(season_id) +
             name_bytes.pack("C*") +
             schedule.map { |v| Borsh.encode_u64(v.to_i) }.join +
             Borsh.encode_i64(start_at.to_i)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true, is_writable: true },
          { pubkey: vault_pda, is_signer: false, is_writable: false },
          { pubkey: pda, is_signer: false, is_writable: true },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      Rails.cache.delete("seasons:all")
      { signature: signature, pda: Keypair.encode_base58(pda), season_id: season_id }
    end

    # List every Season account on the program. 60s cache.
    def list_seasons(commitment: "confirmed")
      Rails.cache.fetch("seasons:all", expires_in: 60.seconds) do
        # Same gem-API gap as list_entry_tokens — bridge via private JSON-RPC.
        result = client.send(:call, "getProgramAccounts", [
          Keypair.encode_base58(@program_id),
          {
            encoding: "base64",
            commitment: commitment,
            filters: [{ dataSize: SEASON_LEN }]
          }
        ])
        (result || []).map { |account| decode_season(account) }.sort_by { |s| s[:season_id] }
      end
    end

    def get_season(season_id, commitment: "confirmed")
      pda, _ = season_pda(season_id)
      info = client.get_account_info(Keypair.encode_base58(pda), commitment: commitment)
      return nil unless info&.dig("value")
      decode_season({ "pubkey" => Keypair.encode_base58(pda), "account" => info["value"] })
    end

    # How many seeds will the on-chain program award for `entry_num` under the given
    # (or current) season? Falls back to SEASON_DEFAULT_SCHEDULE if the season can't
    # be read — keeps the modal response sensible even mid-deploy or in tests.
    def seeds_for_entry(entry_num, season_id: nil)
      season_id ||= SeasonConfig.current_season_id
      season = season_id.to_i.positive? ? (get_season(season_id) rescue nil) : nil
      schedule = season ? season[:seed_schedule] : SEASON_DEFAULT_SCHEDULE
      schedule[[entry_num.to_i, 4].min]
    end

    # Fetch native SOL and SPL token balances for a wallet address
    def fetch_wallet_balances(wallet_address)
      sol_result = client.get_balance(wallet_address)
      sol_lamports = sol_result.is_a?(Hash) ? sol_result["value"] : sol_result
      sol_balance = sol_lamports.to_f / 1_000_000_000

      tokens = {}
      begin
        result = client.get_token_accounts_by_owner(wallet_address)
        if result && result["value"]
          result["value"].each do |account|
            parsed = account.dig("account", "data", "parsed", "info")
            next unless parsed
            mint = parsed["mint"]
            amount = parsed.dig("tokenAmount", "uiAmount") || 0
            tokens[mint] = amount
          end
        end
      rescue Solana::Client::RpcError
        # Token accounts may not exist yet — that's fine
      end

      {
        sol: sol_balance,
        usdc: Config::USDC_MINT.present? ? (tokens[Config::USDC_MINT] || 0) : nil,
        usdt: Config::USDT_MINT.present? ? (tokens[Config::USDT_MINT] || 0) : nil,
        tokens: tokens
      }
    end

    private

    def build_tx(signer)
      blockhash = client.get_latest_blockhash
      tx = Transaction.new
      tx.set_recent_blockhash(blockhash)
      tx.add_signer(signer)
      tx
    end

    # Anchor error 3012 (AccountNotInitialized — "custom program error: 0xbc4")
    # surfaces transiently when a just-created PDA — e.g. a first-time entrant's
    # UserAccount — hasn't reached the RPC node running the next transaction's
    # preflight simulation. Retry with backoff; it clears within seconds once
    # the account is cluster-visible. The block rebuilds the TX each attempt so
    # it picks up a fresh blockhash.
    def with_account_init_retry(attempts: 4)
      tries = 0
      begin
        tries += 1
        yield
      rescue => e
        msg = e.message.to_s
        transient = msg.include?("0xbc4") || msg.include?("AccountNotInitialized")
        raise unless transient && tries < attempts
        sleep(tries * 2)
        retry
      end
    end

    def b(str)
      str.b
    end

    # Decode a single Season account from getProgramAccounts / getAccountInfo result.
    def decode_season(account)
      data = Base64.decode64(account.dig("account", "data", 0))
      offset = 8 # skip discriminator
      season_id, offset = Borsh.decode_u32(data, offset)
      name_bytes = data[offset, 32]; offset += 32
      name = name_bytes.bytes.take_while { |b| b != 0 }.pack("C*").force_encoding("UTF-8")
      schedule = []
      5.times do
        v, offset = Borsh.decode_u64(data, offset)
        schedule << v
      end
      start_at, offset = Borsh.decode_u64(data, offset)  # i64 stored as 8 bytes; for any real timestamp the sign bit is 0
      created_at, offset = Borsh.decode_u64(data, offset)
      {
        pda: account["pubkey"],
        season_id: season_id,
        name: name,
        seed_schedule: schedule,
        start_at: start_at,
        created_at: created_at
      }
    end

    # Decode a single EntryTokenAccount from getProgramAccounts result.
    # Anchor Option<i64> serialization: 1-byte tag (0=None, 1=Some), followed by 8-byte i64
    # in either case — the payload slot is always allocated. We always advance 9 bytes.
    def decode_entry_token(account)
      data = Base64.decode64(account.dig("account", "data", 0))
      offset = 8 # skip Anchor account discriminator
      owner_bytes, offset = Borsh.decode_pubkey(data, offset)
      source = data[offset].ord; offset += 1
      ref_slice = data[offset, 64]; offset += 64
      # source_ref is a 64-byte fixed array padded with 0x00 — trim trailing zeros for display
      source_ref = ref_slice.bytes.take_while { |b| b != 0 }.pack("C*").force_encoding("UTF-8")
      consumed = data[offset].ord == 1; offset += 1
      consumed_at_tag = data[offset].ord; offset += 1
      consumed_at_value, _ = Borsh.decode_u64(data, offset)
      consumed_at = consumed_at_tag == 1 ? consumed_at_value : nil
      offset += 8 # payload slot is always 8 bytes regardless of tag
      created_at, offset = Borsh.decode_u64(data, offset)
      {
        pda: account["pubkey"],
        owner: Keypair.encode_base58(owner_bytes),
        source: source,
        source_ref: source_ref,
        consumed: consumed,
        consumed_at: consumed_at,
        created_at: created_at
      }
    end
  end
end
