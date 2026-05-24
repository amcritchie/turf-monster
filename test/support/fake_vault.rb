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

  def initialize(fail_after: nil, starting_sequence: 0, tokens: [])
    @fail_after = fail_after
    @starting_sequence = starting_sequence
    @tokens = tokens
    @mint_calls = []
    @transfer_calls = []
    @enter_calls = []
    @ensure_account_calls = []
    @fund_calls = []
    @deposit_calls = []
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

  # --- PDA / ATA bootstrapping (no-op stubs) ---

  def ensure_user_account(wallet)
    @ensure_account_calls << wallet
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
