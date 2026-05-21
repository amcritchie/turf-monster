require "test_helper"

class EntryTest < ActiveSupport::TestCase
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

  test "confirm! activates a paid entry given payment proof" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(tx_signature: "paid-tx-sig")

    assert entry.active?
  end

  test "confirm! rejects a paid entry with no payment proof" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_match(/payment required/i, error.message)
    assert entry.reload.cart?
  end

  test "confirm! activates a comped entry without payment" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(comped: true)

    assert entry.active?
  end

  test "confirm! rejects with less than 6 selections" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_match(/selections required/, error.message)
    assert entry.reload.cart?
  end

  test "confirm! rejects for non-open contest" do
    @contest.update!(status: "locked")
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_equal "Contest is not open", error.message
  end

  test "confirm! accepts tx_signature parameter" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(tx_signature: "fake_tx_sig_123")

    assert entry.active?
    assert_equal "fake_tx_sig_123", entry.onchain_tx_signature
  end

  test "confirm! leaves onchain fields nil for an off-chain contest" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(comped: true)

    assert entry.active?
    assert_nil entry.onchain_tx_signature
    assert_nil entry.onchain_entry_id
  end

  test "confirm! stores onchain_entry_id" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(tx_signature: "tx_123", onchain_entry_id: "pda_addr_456")

    assert entry.active?
    assert_equal "tx_123", entry.onchain_tx_signature
    assert_equal "pda_addr_456", entry.onchain_entry_id
  end

  # --- toggle_selection! tests ---

  test "toggle_selection! creates a new selection" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    selections_hash = entry.toggle_selection!(@m1)

    assert_equal({ @m1.id.to_s => true }, selections_hash)
    assert_equal 1, entry.selections.count
  end

  test "toggle_selection! removes selection when toggled again" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.selections.create!(slate_matchup: @m1)

    result = entry.toggle_selection!(@m1)

    assert_nil result
    assert_not Entry.exists?(entry.id)
  end

  test "confirm! rejects duplicate selection combo (sybil check)" do
    # First entry
    entry1 = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry1.selections.create!(slate_matchup: m) }
    entry1.confirm!(comped: true)

    # Second entry with same combo
    entry2 = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry2.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry2.confirm! }
    assert_match(/already have an entry/, error.message)
  end

  # --- slug test ---

  test "slug includes id after creation" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.reload
    assert_includes entry.slug, entry.id.to_s
  end

  test "to_param returns slug" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.reload
    assert_equal entry.slug, entry.to_param
  end

  test "confirm! rejects when a game has already started" do
    # Link m1 to a past game (kickoff in the past = locked)
    @m1.update!(game_slug: "past-game")

    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_match(/already started/, error.message)
    assert entry.reload.cart?
  end

  test "confirm! rejects when user has reached per-contest entry limit" do
    # Create 3 confirmed entries with different combos
    # We only have 6 matchups, so we need different combos — use subsets
    # Actually with 6 matchups and picks_required=6, all combos are the same.
    # So we need more matchups. Let's mock the limit directly.
    # Create entries that are already active to fill the limit.
    3.times do |i|
      entry = @contest.entries.create!(user: @user, status: :active)
    end

    # Try to confirm a 4th entry
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_match(/Maximum 3 entries per contest/, error.message)
  end

end
