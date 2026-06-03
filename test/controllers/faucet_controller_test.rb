require "test_helper"
require "minitest/mock"

class FaucetControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:sam)          # has web3_solana_address (phantom wallet)
    @user_no_wallet = users(:alex) # no solana wallet
  end

  # --- show ---

  test "show is accessible without login" do
    get faucet_path
    assert_response :success
    assert_select "h1", /Devnet Faucet/
  end

  test "show displays claim button when logged in with wallet" do
    log_in_as(@user)
    get faucet_path
    assert_response :success
    assert_select "button", /Claim/
  end

  test "show displays connect wallet CTA when logged in without wallet" do
    log_in_as(@user_no_wallet)
    get faucet_path
    assert_response :success
    assert_select "a[href=?]", account_path
  end

  test "show displays sign-in CTA when not logged in" do
    get faucet_path
    assert_response :success
    assert_select "a[href=?]", signin_path
  end

  # --- claim ---

  test "claim requires login" do
    post faucet_path, params: { amount: 50 }, as: :json
    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
  end

  test "claim mints USDC and creates transaction log" do
    log_in_as(@user)

    mock_vault = Minitest::Mock.new
    mock_vault.expect :ensure_ata, { ata: "fake_ata", created: false, signature: nil }, [String], mint: String
    mock_vault.expect :mint_spl, { signature: "fake_tx_sig" }, [Integer], mint: String, to: String

    Solana::Vault.stub :new, mock_vault do
      assert_difference "TransactionLog.count", 1 do
        post faucet_path, params: { amount: 50 }, as: :json
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "fake_tx_sig", json["tx"]

    txn = TransactionLog.last
    assert_equal "faucet", txn.transaction_type
    assert_equal 50_00, txn.amount_cents
    assert_equal "credit", txn.direction
    assert_equal @user, txn.user
  end

  test "claim rejects zero amount" do
    log_in_as(@user)

    assert_no_difference "TransactionLog.count" do
      post faucet_path, params: { amount: 0 }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match /between \$1 and \$500/, json["error"]
  end

  test "claim rejects amount over 500" do
    log_in_as(@user)

    assert_no_difference "TransactionLog.count" do
      post faucet_path, params: { amount: 501 }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match /between \$1 and \$500/, json["error"]
  end

  test "claim rejects negative amount" do
    log_in_as(@user)

    assert_no_difference "TransactionLog.count" do
      post faucet_path, params: { amount: -10 }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match /between \$1 and \$500/, json["error"]
  end
end
