require "test_helper"

# v0.17: locking is a DERIVED property (on-chain lock_timestamp, mirrored to
# starts_at), not a status flip. These pin the Rails-side mirror: Contest#locked?
# and the lock_timestamp threaded into onchain_params.
class ContestLockingTest < ActiveSupport::TestCase
  setup do
    @contest = Contest.create!(
      name: "Lock derive #{SecureRandom.hex(2)}",
      slate: slates(:one),
      rank: 7000 + rand(900),
      contest_type: "standard",
      user: users(:alex),
      status: "open",
      max_entries: 29,
      starts_at: 1.hour.from_now
    )
  end

  test "locked? is false while starts_at is in the future" do
    @contest.update!(starts_at: 1.hour.from_now)
    assert_not @contest.locked?
  end

  test "locked? is true once starts_at has passed" do
    @contest.update!(starts_at: 1.minute.ago)
    assert @contest.locked?
  end

  test "locked? is false when starts_at is nil (manual-only, never auto-locks)" do
    @contest.update!(starts_at: nil)
    assert_not @contest.locked?
  end

  test "locked? is true for a settled contest regardless of starts_at" do
    @contest.update!(status: "settled", starts_at: 1.hour.from_now)
    assert @contest.locked?
  end

  test "onchain_params carries lock_timestamp from starts_at" do
    ts = 2.hours.from_now.change(usec: 0)
    @contest.update!(starts_at: ts)
    assert_equal ts.to_i, @contest.onchain_params[:lock_timestamp]
  end

  test "onchain_params lock_timestamp is 0 when starts_at is nil" do
    @contest.update!(starts_at: nil)
    assert_equal 0, @contest.onchain_params[:lock_timestamp]
  end

  # --- concluded? (v0.18 derived conclusion) ---

  test "concluded? is false while concludes_at is in the future" do
    @contest.update!(concludes_at: 1.hour.from_now)
    assert_not @contest.concluded?
  end

  test "concluded? is true once concludes_at has passed" do
    @contest.update!(concludes_at: 1.minute.ago)
    assert @contest.concluded?
  end

  test "concluded? is false when concludes_at is nil" do
    @contest.update!(concludes_at: nil)
    assert_not @contest.concluded?
  end

  test "concluded? is true for a settled contest regardless of concludes_at" do
    @contest.update!(status: "settled", concludes_at: 1.hour.from_now)
    assert @contest.concluded?
  end
end
