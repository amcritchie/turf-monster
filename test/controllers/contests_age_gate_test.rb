require "test_helper"

# Entry-time age gate (ENABLE_AGE_GATE) — the server-side authoritative guard
# on the entry endpoints, and the session-context flags the client reads.
class ContestsAgeGateTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    @contest.update!(onchain_contest_id: "onchain-agegate", season_id: 1)
    @user = users(:sam)
  end

  def with_age_gate
    ENV["ENABLE_AGE_GATE"] = "true"
    yield
  ensure
    ENV.delete("ENABLE_AGE_GATE")
  end

  test "session-context exposes ageGateRequired + ageVerified" do
    @user.update!(web3_solana_address: "Web3Age#{SecureRandom.hex(3)}")
    log_in_as_onchain(@user)
    with_age_gate do
      get contest_path(@contest)
      ctx = JSON.parse(response.body[/<script type="application\/json" id="session-context">(.*?)<\/script>/m, 1])
      assert_equal true,  ctx["ageGateRequired"]
      assert_equal false, ctx["ageVerified"], "unverified user must be ageVerified:false"
    end
  end

  test "prepare_entry is blocked with age_required when the user hasn't verified" do
    @user.update!(web3_solana_address: "Web3Prep#{SecureRandom.hex(3)}", age_attested_at: nil)
    log_in_as_onchain(@user)
    with_age_gate do
      post prepare_entry_contest_path(@contest), as: :json
      assert_response :unprocessable_entity
      body = JSON.parse(response.body)
      assert body["age_required"]
      assert_equal "age_required", body.dig("blocker", "reason")
    end
  end

  test "prepare_entry is NOT age-blocked once the user has verified" do
    @user.update!(web3_solana_address: "Web3Ok#{SecureRandom.hex(3)}", age_attested_at: Time.current)
    log_in_as_onchain(@user)
    with_age_gate do
      post prepare_entry_contest_path(@contest), as: :json
      # It may fail later gates (no picks, etc.) but NOT with age_required.
      body = JSON.parse(response.body) rescue {}
      assert_not body["age_required"], "verified user must clear the age gate"
    end
  end

  test "the gate is OFF when ENABLE_AGE_GATE is unset (prod default)" do
    @user.update!(web3_solana_address: "Web3Off#{SecureRandom.hex(3)}", age_attested_at: nil)
    log_in_as_onchain(@user)
    post prepare_entry_contest_path(@contest), as: :json
    body = JSON.parse(response.body) rescue {}
    assert_not body["age_required"], "flag off → no age gate"
  end
end
