require "test_helper"

# Audit C1 — admin blind-cosign. confirm_onchain_entry used to hand raw client
# bytes straight to the admin cosign (Transaction.cosign_wire signs the EXACT
# client message), so a crafted SystemProgram.transfer{from: admin} /
# mint_entry_token / grant_seeds would be admin-signed and broadcast.
#
# Vault#assert_entry_cosign_safe! now DECODES the Phantom-signed wire and
# semantically allowlists it BEFORE any admin signature: admin fee-payer, exactly
# one enter_contest IX bound to THIS entry's PDA, and only the durable-nonce
# advance / ComputeBudget hints alongside. Byte-equality is intentionally NOT
# used — the client round-trips the tx through web3.js, which may re-encode the
# message bytes — so these tests exercise legit builds via #build_enter_contest.
class Solana::VaultCosignValidationTest < ActiveSupport::TestCase
  # A real entrant wallet — MUST differ from the admin managed wallet (the
  # fee-payer): enter_contest marks BOTH admin (payer) and this wallet (user) as
  # signers. (Mason's seed wallet; admin / Alex Bot is 8K81w4e6…aRYd.)
  WALLET = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  SLUG   = "cosign-validation-test".freeze

  FakeContest = Struct.new(:slug)
  FakeEntry   = Struct.new(:id, :entry_number, :contest)

  def entry_for(entry_number: 0)
    FakeEntry.new(7, entry_number, FakeContest.new(SLUG))
  end

  # 80-byte initialized nonce account: version=1, state=1, authority, nonce, fee.
  def nonce_buffer(authority_b58:, nonce_b58:)
    [1].pack("L<") + [1].pack("L<") +
      Solana::Keypair.decode_base58(authority_b58) +
      Solana::Keypair.decode_base58(nonce_b58) + [5000].pack("Q<")
  end

  def fake_client(nonce_b64: nil)
    c = Object.new
    c.define_singleton_method(:get_account_info) { |_pk, **_o| { "value" => { "data" => [nonce_b64, "base64"] } } }
    c.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    c
  end

  def with_durable_nonce_env(pubkey)
    prev = ENV["SOLANA_DURABLE_NONCE_PUBKEY"]
    ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = pubkey
    yield
  ensure
    if prev.nil? then ENV.delete("SOLANA_DURABLE_NONCE_PUBKEY") else ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = prev end
  end

  setup { @nonce_env_prev = ENV.delete("SOLANA_DURABLE_NONCE_PUBKEY") }
  teardown { ENV["SOLANA_DURABLE_NONCE_PUBKEY"] = @nonce_env_prev unless @nonce_env_prev.nil? }

  # --- legit entries PASS ------------------------------------------------------

  test "a legit enter_contest (no durable nonce) passes" do
    vault = Solana::Vault.new(client: fake_client)
    out = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)

    assert vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 0), wallet_address: WALLET)
  end

  test "a legit enter_contest anchored on the durable nonce passes" do
    authority = Solana::Keypair.admin.address
    nonce_val = Solana::Keypair.generate.to_base58
    buf   = nonce_buffer(authority_b58: authority, nonce_b58: nonce_val)
    vault = Solana::Vault.new(client: fake_client(nonce_b64: Base64.strict_encode64(buf)))

    # The advance ix targets the configured SOLANA_DURABLE_NONCE_PUBKEY — the
    # validator reads the SAME env var, so build + assert must share the block.
    with_durable_nonce_env(Solana::Keypair.generate.to_base58) do
      out = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
      assert vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 0), wallet_address: WALLET)
    end
  end

  test "a Phantom-injected Lighthouse assertion alongside enter_contest passes" do
    vault = Solana::Vault.new(client: fake_client)
    admin = Solana::Keypair.admin
    entry_pda_bytes = vault.entry_pda(SLUG, WALLET, 0).first

    # Mimic Phantom transaction protection on mainnet: the tx we prepared
    # (enter_contest) PLUS a Lighthouse post-state assertion injected at sign
    # time. Without the allowlist case this rejected with disallowed_program
    # and blocked every protected Phantom entry (prod, 2026-06-11).
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(admin)
    accounts = Array.new(Solana::Vault::ENTER_CONTEST_ENTRY_PDA_POSITION) do
      { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: false }
    end
    accounts << { pubkey: entry_pda_bytes, is_signer: false, is_writable: true }
    tx.add_instruction(
      program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID),
      accounts: accounts,
      data: Solana::Transaction.anchor_discriminator("enter_contest") + ("\x00".b * 8)
    )
    tx.add_instruction(
      program_id: Solana::Vault::LIGHTHOUSE_PROGRAM_ID,
      accounts: [{ pubkey: Solana::Keypair.decode_base58(WALLET), is_signer: false, is_writable: false }],
      data: "\x02\x00\x01".b # opaque assertion payload — contents are not inspected
    )

    assert vault.assert_entry_cosign_safe!(tx.serialize_base64,
                                           entry: entry_for(entry_number: 0),
                                           wallet_address: WALLET)
  end

  # --- malicious / mismatched wires REJECT ------------------------------------

  test "admin-fee-payer SystemProgram.transfer is rejected (the C1 attack)" do
    vault    = Solana::Vault.new(client: fake_client)
    admin    = Solana::Keypair.admin
    attacker = Solana::Keypair.generate

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(admin)
    tx.add_instruction(
      program_id: Solana::Transaction::SYSTEM_PROGRAM_ID,
      accounts: [
        { pubkey: admin.public_key_bytes,    is_signer: true,  is_writable: true }, # from: admin
        { pubkey: attacker.public_key_bytes, is_signer: false, is_writable: true }  # to:   attacker
      ],
      data: [2].pack("V") + [5_000_000].pack("Q<") # SystemInstruction::Transfer (opcode 2)
    )

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(tx.serialize_base64, entry: entry_for(entry_number: 0), wallet_address: WALLET)
    end
    assert_match(/system_not_advance/, err.message)
  end

  test "a turf-vault instruction that is not enter_contest is rejected" do
    vault = Solana::Vault.new(client: fake_client)
    admin = Solana::Keypair.admin

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(admin)
    tx.add_instruction(
      program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID),
      accounts: [{ pubkey: admin.public_key_bytes, is_signer: true, is_writable: true }],
      data: Solana::Transaction.anchor_discriminator("mint_entry_token") + ("\x00".b * 4)
    )

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(tx.serialize_base64, entry: entry_for(entry_number: 0), wallet_address: WALLET)
    end
    assert_match(/wrong_turf_vault_ix/, err.message)
  end

  test "enter_contest bound to the WRONG entry index is rejected" do
    vault = Solana::Vault.new(client: fake_client)
    out = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)

    # The wire enters slot 0, but the server expects entry_number 1 for THIS entry.
    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 1), wallet_address: WALLET)
    end
    assert_match(/entry_pda_mismatch/, err.message)
  end

  test "a fee payer that is not the admin wallet is rejected" do
    vault     = Solana::Vault.new(client: fake_client)
    not_admin = Solana::Keypair.generate

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(not_admin)
    tx.add_instruction(
      program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID),
      accounts: [{ pubkey: not_admin.public_key_bytes, is_signer: true, is_writable: true }],
      data: Solana::Transaction.anchor_discriminator("enter_contest") + [0].pack("V") + [0].pack("C")
    )

    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(tx.serialize_base64, entry: entry_for(entry_number: 0), wallet_address: WALLET)
    end
    assert_match(/fee_payer_not_admin/, err.message)
  end

  test "an advanceNonceAccount with NO durable nonce configured is rejected" do
    # Build WITH the nonce env so the advance ix is present, then validate with it
    # UNSET — mirrors a stale/misconfigured server that must not blind-cosign.
    authority = Solana::Keypair.admin.address
    nonce_val = Solana::Keypair.generate.to_base58
    buf   = nonce_buffer(authority_b58: authority, nonce_b58: nonce_val)
    vault = Solana::Vault.new(client: fake_client(nonce_b64: Base64.strict_encode64(buf)))

    out = with_durable_nonce_env(Solana::Keypair.generate.to_base58) do
      vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    end

    # env now unset (teardown baseline) → advance ix present but unconfigured.
    err = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(out[:serialized_tx], entry: entry_for(entry_number: 0), wallet_address: WALLET)
    end
    assert_match(/advance_without_config/, err.message)
  end
end
