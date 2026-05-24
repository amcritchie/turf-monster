require "test_helper"
require "minitest/mock"

# BL3 (Stage 3 audit): same shape as StripeDepositJob, idempotency on moonpay_tx_id.
class MoonpayDepositJobTest < ActiveJob::TestCase
  setup do
    @user = users(:jordan)
    @wallet = "ManagedAddr#{SecureRandom.hex(2)}"
    @tx_id = "moonpay_#{SecureRandom.hex(4)}"
  end

  test "managed-wallet path: ensure_user_account + deposit, records TransactionLog" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    vault = FakeVault.new

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        MoonpayDepositJob.perform_now(user_id: @user.id, amount_cents: 7500, wallet_address: @wallet, moonpay_tx_id: @tx_id)
      end
    end

    log = TransactionLog.find_by(moonpay_tx_id: @tx_id)
    assert log
    assert_equal 7500, log.amount_cents
    assert_equal "deposit", log.transaction_type
    assert_equal 1, vault.deposit_calls.length
    assert_equal 1, vault.ensure_account_calls.length
  end

  test "phantom-wallet path: no vault.deposit (USDC already in ATA)" do
    @user.update!(web3_solana_address: @wallet, web2_solana_address: nil)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      MoonpayDepositJob.perform_now(user_id: @user.id, amount_cents: 5000, wallet_address: @wallet, moonpay_tx_id: @tx_id)
    end

    log = TransactionLog.find_by(moonpay_tx_id: @tx_id)
    assert log
    assert_nil log.onchain_tx
    assert_equal 0, vault.deposit_calls.length
  end

  test "idempotency: re-delivered webhook does NOT double-credit (early return)" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    TransactionLog.record!(user: @user, type: "deposit", amount_cents: 7500, direction: "credit", moonpay_tx_id: @tx_id)

    vault = FakeVault.new
    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        MoonpayDepositJob.perform_now(user_id: @user.id, amount_cents: 7500, wallet_address: @wallet, moonpay_tx_id: @tx_id)
      end
    end

    assert_equal 1, TransactionLog.where(moonpay_tx_id: @tx_id).count
    assert_equal 0, vault.deposit_calls.length
  end

  test "race: DB unique index catches duplicate when exists? bypassed" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    vault = FakeVault.new

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        MoonpayDepositJob.perform_now(user_id: @user.id, amount_cents: 7500, wallet_address: @wallet, moonpay_tx_id: @tx_id)

        TransactionLog.stub :exists?, false do
          assert_nothing_raised do
            MoonpayDepositJob.perform_now(user_id: @user.id, amount_cents: 7500, wallet_address: @wallet, moonpay_tx_id: @tx_id)
          end
        end
      end
    end

    assert_equal 1, TransactionLog.where(moonpay_tx_id: @tx_id).count
  end
end
