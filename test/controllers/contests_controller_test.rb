require "test_helper"
require "minitest/mock"

class ContestsControllerTest < ActionDispatch::IntegrationTest
  # FakeVault is shared — see test/support/fake_vault.rb (LW1 extraction).
  setup do
    @contest = contests(:one)
    @user = users(:sam)
    @m1 = slate_matchups(:m1)
    @m2 = slate_matchups(:m2)
    @m3 = slate_matchups(:m3)
    @m4 = slate_matchups(:m4)
    @m5 = slate_matchups(:m5)
    @m6 = slate_matchups(:m6)
  end

  # --- toggle_selection tests ---

  test "toggle_selection creates entry and selection on first toggle" do
    log_in_as(@user)

    assert_difference ["Entry.count", "Selection.count"], 1 do
      post toggle_selection_contest_path(@contest),
        params: { matchup_id: @m1.id },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal({ @m1.id.to_s => true }, json["selections"])
    assert_equal 1, json["selection_count"]
  end

  test "toggle_selection removes selection when toggled again" do
    log_in_as(@user)

    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.selections.create!(slate_matchup: @m1)

    assert_difference "Selection.count", -1 do
      post toggle_selection_contest_path(@contest),
        params: { matchup_id: @m1.id },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal({}, json["selections"])
    assert_equal 0, json["selection_count"]
    # Entry should be destroyed when empty
    assert_not Entry.exists?(entry.id)
  end

  test "toggle_selection requires authentication" do
    post toggle_selection_contest_path(@contest),
      params: { matchup_id: @m1.id },
      as: :json

    assert_response :redirect
    assert_redirected_to login_path
  end

  # --- enter (confirm) tests ---

  test "enter confirms cart entry with JSON" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(contest),
      headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert json["redirect"]
    assert entry.reload.active?
  end

  test "enter with JSON redirects when no cart entry" do
    log_in_as(@user)

    post enter_contest_path(@contest),
      headers: { "Accept" => "application/json" }

    assert_response :redirect
  end

  test "enter requires authentication" do
    post enter_contest_path(@contest)

    assert_response :redirect
    assert_redirected_to login_path
  end

  test "enter with HTML redirects on success" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(contest)

    assert_response :redirect
    # ContestsController#enter redirects to /c/:id/lobby (see contest_lobby_path),
    # not /contests/:id. Updated 2026-05-23 to match current behavior.
    assert_redirected_to contest_lobby_path(contest)
  end

  # --- onchain session entry tests ---

  test "enter rejects onchain session without signature" do
    key = log_in_as_onchain(@user)

    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(@contest),
      headers: { "Accept" => "application/json" }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/Wallet signature required/, json["error"])
    assert entry.reload.cart?
  end

  test "enter accepts onchain session with valid signature" do
    key = log_in_as_onchain(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    signed_params = sign_entry_message(key, @user, contest.name)

    post enter_contest_path(contest),
      params: signed_params,
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert entry.reload.active?
  end

  test "enter rejects onchain session with wrong wallet" do
    key = log_in_as_onchain(@user)

    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    # Sign with correct key but then change the user's wallet to something else
    signed_params = sign_entry_message(key, @user, @contest.name)
    @user.update!(web3_solana_address: "DifferentWalletAddress1111111111111111111111111")

    post enter_contest_path(@contest),
      params: signed_params,
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/Wallet mismatch/, json["error"])
    assert entry.reload.cart?
  end

  test "enter works for offchain session" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(contest),
      headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert entry.reload.active?
  end

  test "enter rejects a paid contest that is not on-chain" do
    log_in_as(@user)
    # contests(:one) is paid ($19) but has no onchain_contest_id — the exact
    # state that used to hand out a free entry. The payment gate must refuse it.
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(@contest),
      headers: { "Accept" => "application/json" }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/on-chain/i, json["error"])
    assert entry.reload.cart?, "an unpaid entry must never be activated"
  end

  # --- web2 / managed-wallet token spend ---

  test "enter consumes on-chain token via vault.enter_contest_with_token for managed-wallet users" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])
    Solana::Keypair.stub :from_encrypted, "fake-keypair-object" do
      Solana::Vault.stub :new, vault do
        post enter_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"], "expected entry success, got: #{json["error"]}"
    assert_equal 1, vault.enter_calls.length
    assert_equal :enter_contest_with_token, vault.enter_calls.first[:method]
    assert_equal "tpda_1", vault.enter_calls.first[:token_pda]
    assert entry.reload.active?
  end

  test "enter blocks managed-wallet user with no tokens via 'No entry tokens' error" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [])
    Solana::Vault.stub :new, vault do
      post enter_contest_path(@contest), as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/No entry tokens/, JSON.parse(response.body)["error"])
    assert entry.reload.cart?
    assert_equal 0, vault.enter_calls.length
  end

  # --- page load tests ---

  test "index loads" do
    get contests_path
    assert_response :success
  end

  test "show loads" do
    get contest_path(@contest)
    assert_response :success
  end

  test "world_cup redirects to contest show" do
    get root_path
    assert_redirected_to contest_path(@contest)
  end

  test "world_cup redirects to index when no contests" do
    Contest.update_all(status: :pending)
    get root_path
    assert_redirected_to contests_path
  end

  # --- show tests (formerly lobby; merged 2026-05-17) ---

  test "show loads for guest" do
    get contest_path(@contest)
    assert_response :success
  end

  test "show loads for logged in user" do
    log_in_as(@user)
    get contest_path(@contest)
    assert_response :success
  end

  test "show renders matchup board when user not in contest" do
    log_in_as(@user)
    get contest_path(@contest)
    assert_response :success
    assert_select "section" # board renders inline
  end

  test "show renders 'Add Nth Entry' link when user already has an entry" do
    log_in_as(@user)
    entry = @contest.entries.create!(user: @user, status: :active)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    get contest_path(@contest)
    assert_response :success
    assert_select "a", text: /Add 2nd Entry/
  end

  test "show redirects for missing contest" do
    get contest_path(id: "nonexistent")
    assert_redirected_to root_path
  end

  # --- legacy lobby URL backwards-compat ---

  test "legacy lobby URL 301-redirects to canonical show URL" do
    get contest_lobby_path(@contest)
    assert_response :moved_permanently
    assert_redirected_to contest_path(@contest)
  end

  # --- generate_bundle (provision setup bundles) ---

  test "generator page renders for admins" do
    log_in_as(users(:alex))
    get generator_contests_path
    assert_response :success
  end

  test "generate_bundle provisions a bundle for admins" do
    log_in_as(users(:alex))
    assert_difference ["Contest.count", "LandingPage.count"], 1 do
      post generate_bundle_contests_path(key: "survivor")
    end
    assert_redirected_to generator_contests_path
  end

  test "generate_bundle is admin-only" do
    log_in_as(@user) # users(:sam) — not an admin
    post generate_bundle_contests_path(key: "survivor")
    assert_response :redirect
    assert_not LandingPage.exists?(slug: "survivor")
  end

  private

  # A free, off-chain contest — the only kind a successful #enter can be
  # exercised against without a Solana RPC mock (paid entries need a real
  # on-chain token consume / vault transfer). Free entries skip the payment gate.
  def free_contest
    Contest.create!(
      name: "Free Plumbing Contest",
      slate: slates(:one),
      contest_type: "standard",
      entry_fee_cents: 0,
      max_entries: 29,
      status: :open,
      starts_at: 2.weeks.from_now
    )
  end
end
