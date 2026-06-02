require "test_helper"
require "minitest/mock"

# Admin::PendingTransactionsController — the generalized multisig cosign queue.
# Covers the tx_type dispatch added in the unused-instructions cleanup:
# rebuild → the right Vault builder, confirm → the right post-verify DB flip.
# Vault + TxVerifier are stubbed so nothing hits RPC.
class Admin::PendingTransactionsControllerTest < ActionDispatch::IntegrationTest
  USDC = "222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9".freeze

  setup do
    @admin   = users(:alex)
    @contest = contests(:one)
    @contest.update!(onchain_contest_id: "onchain_ptx")
  end

  def ptx(tx_type, metadata, target: nil)
    PendingTransaction.create!(
      tx_type: tx_type,
      serialized_tx: "OLD_TX",
      status: "pending",
      target: target,
      initiator_address: "init",
      metadata: metadata.to_json
    )
  end

  # --- rebuild dispatch ---

  test "rebuild dispatches cancel_contest to build_cancel_contest" do
    log_in_as(@admin)
    tx = ptx("cancel_contest", { creator: "Creator11111111111111111111111111111111111" }, target: @contest)
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal 1, vault.cancel_calls.length
    assert_match(/FAKE_TX_cancel/, tx.reload.serialized_tx)
  end

  test "rebuild dispatches register_currency to build_register_currency" do
    log_in_as(@admin)
    tx = ptx("register_currency", { mint: USDC, kind: 0, op_rev_ata: "oprev" })
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal USDC, vault.register_calls.first[:mint]
    assert_match(/FAKE_TX_register/, tx.reload.serialized_tx)
  end

  test "rebuild dispatches deactivate_currency to build_deactivate_currency" do
    log_in_as(@admin)
    tx = ptx("deactivate_currency", { currency_idx: 2 })
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal 2, vault.deactivate_calls.first[:currency_idx]
  end

  test "rebuild dispatches sweep_operator_revenue to build_sweep_operator_revenue" do
    log_in_as(@admin)
    tx = ptx("sweep_operator_revenue", { currency_mint: USDC, treasury_ata: "t", amount: 0 })
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal USDC, vault.sweep_calls.first[:currency_mint]
  end

  # --- confirm post-verify DB state ---

  test "confirm flips onchain_cancelled for cancel_contest" do
    log_in_as(@admin)
    tx = ptx("cancel_contest", { creator: "c" }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, tx_signature: "sig_cancel" }, as: :json
        end
      end
    end

    assert_equal "confirmed", tx.reload.status
    assert @contest.reload.onchain_cancelled?
    assert_not @contest.onchain_settled?
  end

  test "confirm makes no Contest DB change for register_currency (no target)" do
    log_in_as(@admin)
    tx = ptx("register_currency", { mint: USDC, kind: 0 })
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, tx_signature: "sig_reg" }, as: :json
        end
      end
    end

    assert_equal "confirmed", tx.reload.status
  end

  test "confirm still flips onchain_settled for settle_contest" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, tx_signature: "sig_settle" }, as: :json
        end
      end
    end

    assert @contest.reload.onchain_settled?
  end
end
