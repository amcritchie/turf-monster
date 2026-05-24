require "test_helper"
require "minitest/mock"

# BL3 (Stage 3 audit): real-USD deposit flow. Idempotency depends on the
# OPSEC-022 unique partial index on TransactionLog.stripe_session_id.
class StripeDepositJobTest < ActiveJob::TestCase
  setup do
    @user = users(:jordan)
    @wallet = "ManagedAddr#{SecureRandom.hex(2)}"
    @sid = "cs_test_dep_#{SecureRandom.hex(4)}"
  end

  test "managed-wallet path: ensure_ata + ensure_user_account + fund_user + deposit, records TransactionLog" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    vault = FakeVault.new

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
      end
    end

    log = TransactionLog.find_by(stripe_session_id: @sid)
    assert log
    assert_equal "deposit", log.transaction_type
    assert_equal 2500, log.amount_cents
    assert_equal "credit", log.direction
    assert_match(/fake-deposit-sig/, log.onchain_tx)

    assert_equal 1, vault.ensure_account_calls.length
    assert_equal 1, vault.fund_calls.length
    assert_equal 1, vault.deposit_calls.length
  end

  test "phantom-wallet path: ensure_ata + fund_user only (no vault.deposit)" do
    @user.update!(web3_solana_address: @wallet, web2_solana_address: nil)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 5000, wallet_address: @wallet, stripe_session_id: @sid)
    end

    log = TransactionLog.find_by(stripe_session_id: @sid)
    assert log
    assert_equal 5000, log.amount_cents
    assert_match(/fake-fund/, log.onchain_tx)
    assert_equal 1, vault.fund_calls.length
    assert_equal 0, vault.deposit_calls.length
  end

  test "idempotency: re-delivered webhook does NOT double-credit (early return)" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    TransactionLog.record!(user: @user, type: "deposit", amount_cents: 2500, direction: "credit", stripe_session_id: @sid)

    vault = FakeVault.new
    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
      end
    end

    assert_equal 1, TransactionLog.where(stripe_session_id: @sid).count
    assert_equal 0, vault.deposit_calls.length
    assert_equal 0, vault.fund_calls.length
  end

  test "concurrent race: DB unique index rescues the second insert" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    vault = FakeVault.new

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
      end
    end
    assert_equal 1, TransactionLog.where(stripe_session_id: @sid).count

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        TransactionLog.stub :exists?, false do
          assert_nothing_raised do
            StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
          end
        end
      end
    end
    assert_equal 1, TransactionLog.where(stripe_session_id: @sid).count
  end

  test "unknown user_id is a no-op (early return)" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      assert_nothing_raised do
        StripeDepositJob.perform_now(user_id: 99_999_999, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
      end
    end
    assert_equal 0, TransactionLog.where(stripe_session_id: @sid).count
    assert_equal 0, vault.fund_calls.length
  end
end
