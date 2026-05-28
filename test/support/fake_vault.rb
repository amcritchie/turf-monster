# Shared Solana::Vault stand-in for tests.
# Subsumes the two inline FakeVault classes that used to live in
# token_purchase_job_test.rb and contests_controller_test.rb. Extracted here
# (LW1 in the Stage 3 audit) so the entry-token / dev-mint / balance tests
# that were marked `skip "needs FakeVault methods"` can run.
#
# Usage:
#   vault = FakeVault.new(tokens: [{ pda: "tpda_1" }])
#   Solana::Vault.stub :new, vault do
#     # code under test
#   end
#   assert_equal 1, vault.enter_calls.length
#
# Configurable:
#   fail_after:        integer N → raise on the (N+1)-th mint_entry_token call
#   starting_sequence: integer  → first mint's sequence (for resume tests)
#   tokens:            array    → seeds list_entry_tokens (drives has-tokens branches)
class FakeVault
  attr_reader :mint_calls, :transfer_calls, :enter_calls, :ensure_account_calls,
              :fund_calls, :deposit_calls

  def initialize(fail_after: nil, starting_sequence: 0, tokens: [], signature_statuses: {})
    @fail_after = fail_after
    @starting_sequence = starting_sequence
    @tokens = tokens
    @signature_statuses = signature_statuses
    @mint_calls = []
    @transfer_calls = []
    @enter_calls = []
    @ensure_account_calls = []
    @fund_calls = []
    @deposit_calls = []
  end

  # --- Solana RPC client stub (recovery flow) ---
  #
  # Returns a FakeSolanaClient seeded with the signature_statuses map from
  # initialize. The recovery action calls
  # `Solana::Vault.new.client.confirm_transaction(sig).dig("value", 0)`,
  # so the stub mirrors that envelope shape.
  def client
    @client ||= FakeSolanaClient.new(@signature_statuses)
  end

  # --- Token minting (TokenPurchaseJob, dev_mint) ---

  def mint_entry_token(wallet_address:, source:, source_ref:, **_opts)
    @mint_calls << source_ref
    raise StandardError, "simulated chain failure" if @fail_after && @mint_calls.length > @fail_after
    seq = @starting_sequence + @mint_calls.length - 1
    { signature: "sig_#{seq}_#{SecureRandom.hex(2)}", pda: "pda-seq-#{seq}", sequence: seq }
  end

  def list_entry_tokens(_wallet, **_opts)
    @tokens.dup
  end

  def next_entry_token_sequence(_wallet)
    @starting_sequence + @mint_calls.length
  end

  # --- Offchain USDC transfer (legacy contest entry path) ---

  def transfer_from_user(user, amount, mint:)
    @transfer_calls << { user_id: user.id, amount: amount, mint: mint }
    { signature: "fake-transfer-sig-#{SecureRandom.hex(2)}" }
  end

  # --- On-chain contest entry ---

  def enter_contest_with_token(wallet, slug, entry_number, token_pda, user_keypair:, season_id:)
    @enter_calls << {
      method: :enter_contest_with_token,
      wallet: wallet, slug: slug, entry_number: entry_number,
      token_pda: token_pda, season_id: season_id
    }
    { signature: "fake-enter-with-token-#{SecureRandom.hex(2)}", entry_pda: "epda-#{SecureRandom.hex(2)}" }
  end

  def enter_contest(wallet, slug, entry_number, season_id: nil)
    @enter_calls << {
      method: :enter_contest,
      wallet: wallet, slug: slug, entry_number: entry_number, season_id: season_id
    }
    { signature: "fake-enter-#{SecureRandom.hex(2)}", entry_pda: "epda-#{SecureRandom.hex(2)}" }
  end

  # --- Build-only partial-signed TXs (Phantom co-sign flow) ---
  #
  # Used by ContestsController#prepare_entry. Returns the same envelope shape
  # as the real Solana::Vault#build_enter_contest_direct: serialized_tx plus
  # the predicted entry PDA the user's TX will create.
  # v0.16: renamed from build_enter_contest_direct; now takes currency_idx (0=USDC).
  def build_enter_contest(wallet_address, contest_slug, entry_num, currency_idx: 0, season_id: nil)
    @enter_calls << {
      method: :build_enter_contest,
      wallet: wallet_address, slug: contest_slug,
      entry_number: entry_num, currency_idx: currency_idx, season_id: season_id
    }
    {
      serialized_tx: "FAKE_TX_#{contest_slug}_#{entry_num}",
      entry_pda: "epda-#{contest_slug}-#{wallet_address[0, 4]}-#{entry_num}"
    }
  end

  # Used by ContestsController#confirm_onchain_entry. Real Vault returns
  # [pda_bytes, bump] and the controller passes pda_bytes through
  # Solana::Keypair.encode_base58. For tests, return a tuple whose first
  # element is already a string and stub Solana::Keypair.encode_base58 to
  # identity when calling confirm_onchain_entry.
  def entry_pda(contest_slug, wallet_address, entry_num)
    ["epda-#{contest_slug}-#{wallet_address[0, 4]}-#{entry_num}", 255]
  end

  # --- PDA / ATA bootstrapping (no-op stubs) ---

  def ensure_user_account(wallet, username: nil)
    # v0.16: callers MUST pass username (>= 3 chars) — production Vault
    # rescues to a Ruby ArgumentError client-side before the chain call.
    # Test signature mirrors the real one.
    @ensure_account_calls << { wallet: wallet, username: username }
    { created: false }
  end

  def ensure_ata(wallet, mint:)
    { ata: "fake-ata-#{wallet[0, 4]}-#{mint[0, 4]}", created: false }
  end

  # --- Deposit flow (StripeDepositJob / MoonpayDepositJob) ---

  def fund_user(wallet, lamports)
    @fund_calls << { wallet: wallet, lamports: lamports }
    { signature: "fake-fund-#{SecureRandom.hex(2)}" }
  end

  def deposit(_user_keypair, lamports)
    @deposit_calls << { lamports: lamports }
    "fake-deposit-sig-#{SecureRandom.hex(2)}"
  end

  # --- Reading on-chain state (seeds + balance helpers) ---

  def sync_balance(_wallet)
    { balance_dollars: 0.0, seeds: 0, level: 1 }
  end

  def seeds_for_entry(_entry_number)
    25
  end
end

# Mirrors the relevant slice of Solana::Client used by
# ContestsController#recover_pending_entry. The real RPC returns
# {"value" => [{"err"=>..., "confirmationStatus"=>"confirmed"|"finalized"|"processed"}, ...]}
# (one entry per requested signature); we always batch a single signature
# here, so the array has at most one element. An unknown signature
# returns {"value" => [nil]} per the JSON-RPC spec.
class FakeSolanaClient
  def initialize(statuses)
    @statuses = statuses || {}
  end

  def confirm_transaction(signature)
    { "value" => [@statuses[signature]] }
  end
end
