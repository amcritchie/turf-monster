require "test_helper"

# Entry#assign_onchain_entry_number! — picks the entry's on-chain slot by
# probing the chain (via the vault) instead of counting DB rows, so an orphaned
# Entry PDA left by a contest Reset can't cause a slot collision at EnterContest.
class EntryOnchainSlotTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @user    = users(:sam)
    @wallet  = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr"
  end

  # Minimal vault double: returns `free` from next_free_entry_index and records
  # the args it was called with (so we can assert the skip list).
  def fake_vault(free:)
    v = Object.new
    v.instance_variable_set(:@free, free)
    v.define_singleton_method(:last_call) { @last_call }
    v.define_singleton_method(:next_free_entry_index) do |slug, wallet, max:, skip: []|
      @last_call = { slug: slug, wallet: wallet, max: max, skip: skip }
      @free
    end
    v
  end

  test "sets entry_number to the slot the vault reports free" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.assign_onchain_entry_number!(@wallet, fake_vault(free: 0))
    assert_equal 0, entry.reload.entry_number
  end

  test "re-assigns a provisional number when its on-chain slot is taken" do
    # Simulates the bug: a cart entry already holds slot 0, but slot 0's PDA is
    # orphaned on-chain, so the vault hands back the next free slot (1).
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    entry.assign_onchain_entry_number!(@wallet, fake_vault(free: 1))
    assert_equal 1, entry.reload.entry_number
  end

  test "skips slots claimed by the user's other live entries" do
    @contest.entries.create!(user: @user, status: :active, entry_number: 0)
    entry = @contest.entries.create!(user: @user, status: :cart)
    v = fake_vault(free: 1)
    entry.assign_onchain_entry_number!(@wallet, v)
    assert_includes v.last_call[:skip], 0
  end

  test "is a no-op once the entry is confirmed on-chain" do
    entry = @contest.entries.create!(user: @user, status: :active, entry_number: 2,
                                     onchain_tx_signature: "already-on-chain")
    raising = Object.new
    raising.define_singleton_method(:next_free_entry_index) { |*, **| raise "should not probe" }
    assert_equal 2, entry.assign_onchain_entry_number!(@wallet, raising)
    assert_equal 2, entry.reload.entry_number
  end

  test "raises when the user has used every slot" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    err = assert_raises(RuntimeError) do
      entry.assign_onchain_entry_number!(@wallet, fake_vault(free: nil))
    end
    assert_match(/entry slots/, err.message)
  end
end
