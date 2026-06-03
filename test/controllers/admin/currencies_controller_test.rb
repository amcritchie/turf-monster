require "test_helper"
require "minitest/mock"

# Admin::CurrenciesController — on-chain accepted_currencies registry. The Vault
# (read_vault_state + the register/deactivate/sweep builders) is stubbed via the
# shared FakeVault so nothing hits RPC.
class Admin::CurrenciesControllerTest < ActionDispatch::IntegrationTest
  USDC     = "222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9".freeze
  NEW_MINT = "EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ".freeze # not in the registry

  setup do
    @admin = users(:alex)
    @user  = users(:sam)
  end

  def vault_with_usdc
    state = {
      pda: "vault-pda",
      treasury_authority: "TreaSuryXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
      accepted_currencies: Array.new(16) do |i|
        if i.zero?
          { slot: 0, mint: USDC, op_rev_ata: "oprev-usdc", kind: 0, active: true }
        else
          { slot: i, mint: "11111111111111111111111111111111", op_rev_ata: "11111111111111111111111111111111", kind: 0, active: false }
        end
      end
    }
    v = FakeVault.new
    v.vault_state = state
    v
  end

  # --- require_admin gate ---

  test "index redirects non-admins" do
    log_in_as(@user)
    get admin_currencies_path
    assert_response :redirect
  end

  test "register redirects non-admins (no PendingTransaction)" do
    log_in_as(@user)
    assert_no_difference -> { PendingTransaction.count } do
      post admin_register_currency_path, params: { mint: USDC, kind: 0 }
    end
    assert_response :redirect
  end

  # --- index ---

  test "index lists accepted currencies" do
    log_in_as(@admin)
    Solana::Vault.stub :new, vault_with_usdc do
      get admin_currencies_path
    end
    assert_response :success
    assert_match USDC, response.body
  end

  test "index renders a friendly state when read_vault_state raises" do
    log_in_as(@admin)
    raising = FakeVault.new
    def raising.read_vault_state(**_); raise "RPC down"; end
    Solana::Vault.stub :new, raising do
      get admin_currencies_path
    end
    assert_response :success
    assert_match(/read the vault state/i, response.body)
  end

  # --- register ---

  test "register queues a register_currency PendingTransaction" do
    log_in_as(@admin)
    vault = vault_with_usdc
    assert_difference -> { PendingTransaction.count }, 1 do
      Solana::Vault.stub :new, vault do
        post admin_register_currency_path, params: { mint: NEW_MINT, kind: 1 }
      end
    end
    ptx = PendingTransaction.order(:created_at).last
    assert_equal "register_currency", ptx.tx_type
    assert_nil ptx.target
    assert_equal NEW_MINT, ptx.parsed_metadata["mint"]
    assert_equal 1, ptx.parsed_metadata["kind"]
    assert_redirected_to admin_pending_transactions_path
    assert_equal NEW_MINT, vault.register_calls.first[:mint]
  end

  test "register rejects a mint already in the registry (preflight)" do
    log_in_as(@admin)
    vault = vault_with_usdc
    assert_no_difference -> { PendingTransaction.count } do
      Solana::Vault.stub :new, vault do
        post admin_register_currency_path, params: { mint: USDC, kind: 0 }
      end
    end
    assert_redirected_to admin_currencies_path
  end

  test "register rejects an invalid mint" do
    log_in_as(@admin)
    vault = vault_with_usdc
    assert_no_difference -> { PendingTransaction.count } do
      Solana::Vault.stub :new, vault do
        post admin_register_currency_path, params: { mint: "not-base58!", kind: 0 }
      end
    end
    assert_redirected_to admin_currencies_path
  end

  # --- deactivate ---

  test "deactivate queues a deactivate_currency PendingTransaction" do
    log_in_as(@admin)
    vault = vault_with_usdc
    assert_difference -> { PendingTransaction.count }, 1 do
      Solana::Vault.stub :new, vault do
        post admin_deactivate_currency_path(idx: 0)
      end
    end
    ptx = PendingTransaction.order(:created_at).last
    assert_equal "deactivate_currency", ptx.tx_type
    assert_equal 0, ptx.parsed_metadata["currency_idx"]
    assert_equal 0, vault.deactivate_calls.first[:currency_idx]
  end

  test "deactivate rejects an empty slot (preflight)" do
    log_in_as(@admin)
    vault = vault_with_usdc # only slot 0 populated
    assert_no_difference -> { PendingTransaction.count } do
      Solana::Vault.stub :new, vault do
        post admin_deactivate_currency_path(idx: 5)
      end
    end
    assert_redirected_to admin_currencies_path
  end

  # --- sweep ---

  test "sweep queues a sweep_operator_revenue PendingTransaction when balance > 0" do
    log_in_as(@admin)
    vault = vault_with_usdc
    # Stub the RPC client: treasury ATA exists + op_rev has a positive balance.
    client = Object.new
    def client.get_account_info(_pubkey); { "value" => { "lamports" => 1 } }; end
    def client.get_token_account_balance(_pubkey); { "value" => { "amount" => "5000000" } }; end
    vault.define_singleton_method(:client) { client }

    assert_difference -> { PendingTransaction.count }, 1 do
      Solana::Vault.stub :new, vault do
        post admin_sweep_operator_revenue_path, params: { mint: USDC }
      end
    end
    ptx = PendingTransaction.order(:created_at).last
    assert_equal "sweep_operator_revenue", ptx.tx_type
    assert_equal USDC, ptx.parsed_metadata["currency_mint"]
    assert_equal USDC, vault.sweep_calls.first[:currency_mint]
  end

  test "sweep refuses when op_rev balance is 0" do
    log_in_as(@admin)
    vault = vault_with_usdc
    client = Object.new
    def client.get_account_info(_pubkey); { "value" => { "lamports" => 1 } }; end
    def client.get_token_account_balance(_pubkey); { "value" => { "amount" => "0" } }; end
    vault.define_singleton_method(:client) { client }

    assert_no_difference -> { PendingTransaction.count } do
      Solana::Vault.stub :new, vault do
        post admin_sweep_operator_revenue_path, params: { mint: USDC }
      end
    end
    assert_redirected_to admin_currencies_path
  end

  test "sweep refuses when treasury ATA does not exist" do
    log_in_as(@admin)
    vault = vault_with_usdc
    client = Object.new
    def client.get_account_info(_pubkey); { "value" => nil }; end
    def client.get_token_account_balance(_pubkey); { "value" => { "amount" => "5000000" } }; end
    vault.define_singleton_method(:client) { client }

    assert_no_difference -> { PendingTransaction.count } do
      Solana::Vault.stub :new, vault do
        post admin_sweep_operator_revenue_path, params: { mint: USDC }
      end
    end
    assert_redirected_to admin_currencies_path
  end
end
