require "test_helper"
require "minitest/mock"

class TokenPurchaseJobTest < ActiveJob::TestCase
  class FakeVault
    attr_reader :calls
    def initialize
      @calls = []
    end

    def ensure_ata(addr, mint:)
      @calls << [:ensure_ata, addr, mint]
      { ata: "fake-ata", created: false, signature: nil }
    end

    def fund_user(addr, lamports, mint: :usdc)
      @calls << [:fund_user, addr, lamports]
      { signature: "fake-sig-#{lamports}" }
    end
  end

  setup do
    @user = users(:alex)
    @user.update!(web2_solana_address: "TestWalletAddr", encrypted_web2_solana_private_key: "x")
    @wallet = @user.solana_address
  end

  test "creates N tokens, tops up ATA, logs transaction" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, quantity: 3, wallet_address: @wallet, stripe_session_id: "cs_test_1")
    end

    assert_equal 3, @user.entry_tokens.purchased.count
    assert_equal 3, EntryToken.for_source_ref("cs_test_1").count
    assert_includes vault.calls.map(&:first), :ensure_ata
    assert_includes vault.calls.map(&:first), :fund_user
    log = TransactionLog.where("metadata @> ?", { stripe_session_id: "cs_test_1" }.to_json).first
    assert_not_nil log
    assert_equal "token_purchase", log.transaction_type
    assert_equal 49_00, log.amount_cents
  end

  test "is idempotent on repeat with same session id" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, quantity: 1, wallet_address: @wallet, stripe_session_id: "cs_test_2")
      TokenPurchaseJob.perform_now(user_id: @user.id, quantity: 1, wallet_address: @wallet, stripe_session_id: "cs_test_2")
    end

    assert_equal 1, EntryToken.for_source_ref("cs_test_2").count
    assert_equal 1, TransactionLog.where("metadata @> ?", { stripe_session_id: "cs_test_2" }.to_json).count
  end

  test "bails on unknown user_id" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: 999_999, quantity: 1, wallet_address: "x", stripe_session_id: "cs_missing")
    end
    assert_equal 0, EntryToken.for_source_ref("cs_missing").count
  end
end
