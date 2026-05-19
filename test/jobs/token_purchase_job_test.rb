require "test_helper"
require "minitest/mock"

class TokenPurchaseJobTest < ActiveJob::TestCase
  # Minimal Vault stand-in. Tracks mint_entry_token calls, can simulate a
  # mid-loop failure, and reports a configurable set of "already on-chain"
  # source_refs to exercise the partial-failure resume path.
  class FakeVault
    attr_reader :mint_calls

    def initialize(existing_refs: [], fail_after: nil)
      @existing_refs = existing_refs
      @fail_after = fail_after
      @mint_calls = []
    end

    def list_entry_tokens(_wallet, **_opts)
      @existing_refs.map { |r| { source_ref: r, pda: "pda-#{r}", consumed: false } }
    end

    def next_entry_token_sequence(_wallet)
      @existing_refs.length
    end

    def mint_entry_token(wallet_address:, source:, source_ref:, **_opts)
      @mint_calls << source_ref
      raise StandardError, "simulated chain failure" if @fail_after && @mint_calls.length > @fail_after
      seq = (@existing_refs.length + @mint_calls.length) - 1
      { signature: "sig_#{seq}_#{SecureRandom.hex(2)}", pda: "pda-seq-#{seq}", sequence: seq }
    end
  end

  setup do
    @user = users(:alex)
    @user.update!(web2_solana_address: "TestWallet#{SecureRandom.hex(2)}", encrypted_web2_solana_private_key: "x")
    @wallet = @user.solana_address
    @sid = "cs_test_partial_#{SecureRandom.hex(4)}"
  end

  test "happy path mints all N tokens and writes a minted StripePurchase + TransactionLog" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, quantity: 3, wallet_address: @wallet, stripe_session_id: @sid)
    end

    purchase = StripePurchase.for_session(@sid).first
    assert_equal "minted", purchase.status
    assert_equal 3, purchase.tx_signatures.length
    assert_equal 3, vault.mint_calls.length
    assert vault.mint_calls.all? { |r| r.start_with?("stripe:#{@sid}:") }
    assert TransactionLog.where("metadata @> ?", { stripe_session_id: @sid }.to_json).exists?
  end

  test "partial-failure: retries only the un-minted source_refs" do
    # Simulate a previous run that minted indices 0 and 1, then crashed.
    already_minted = ["stripe:#{@sid}:0", "stripe:#{@sid}:1"]
    vault = FakeVault.new(existing_refs: already_minted)
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, quantity: 3, wallet_address: @wallet, stripe_session_id: @sid)
    end

    # Only the 3rd iteration should have hit the chain on this retry.
    assert_equal 1, vault.mint_calls.length
    assert_equal "stripe:#{@sid}:2", vault.mint_calls.first

    purchase = StripePurchase.for_session(@sid).first
    assert_equal "minted", purchase.status
    assert_equal 1, purchase.tx_signatures.length
  end

  test "mid-loop failure persists captured signatures and leaves StripePurchase in failed state" do
    vault = FakeVault.new(fail_after: 2) # mints 0 and 1, raises on 2
    # Don't assert on raise behaviour — ActiveJob's retry_on may swallow. The
    # contract we care about is the end-state: failed status + persisted sigs.
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, quantity: 3, wallet_address: @wallet, stripe_session_id: @sid) rescue nil
    end
    purchase = StripePurchase.for_session(@sid).first
    assert_equal "failed", purchase.status
    assert_equal 2, purchase.tx_signatures.length, "should have persisted the first two signatures before crash"
    assert_equal 3, vault.mint_calls.length, "should have attempted all three mints (the third raised)"
  end

  test "skip when StripePurchase already minted" do
    StripePurchase.create!(user: @user, stripe_session_id: @sid, quantity: 1, price_cents: 19_00, status: "minted")
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, quantity: 1, wallet_address: @wallet, stripe_session_id: @sid)
    end
    assert_equal 0, vault.mint_calls.length, "should not attempt any mint on already-minted session"
  end

  test "resumes a previously-failed StripePurchase (status: failed → pending → minted)" do
    StripePurchase.create!(user: @user, stripe_session_id: @sid, quantity: 1, price_cents: 19_00, status: "failed")
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, quantity: 1, wallet_address: @wallet, stripe_session_id: @sid)
    end
    purchase = StripePurchase.for_session(@sid).first
    assert_equal "minted", purchase.status
    assert_equal 1, vault.mint_calls.length
  end

  test "bails on unknown user_id without creating a row" do
    Solana::Vault.stub :new, FakeVault.new do
      TokenPurchaseJob.perform_now(user_id: 999_999, quantity: 1, wallet_address: "x", stripe_session_id: @sid)
    end
    assert_nil StripePurchase.for_session(@sid).first
  end
end
