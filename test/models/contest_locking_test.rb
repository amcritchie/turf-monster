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

  test "locked? is false when starts_at is nil and slate start is still future" do
    @contest.update!(starts_at: nil)
    assert_not @contest.locked?
  end

  test "starts_in_at falls back to the slate first game" do
    first_game = Game.create!(
      home_team_slug: "team-a",
      away_team_slug: "team-b",
      kickoff_at: 3.days.from_now.change(usec: 0),
      status: "scheduled"
    )
    slate_matchups(:m1).update!(game_slug: first_game.slug)

    @contest.update!(starts_at: nil)
    assert_equal first_game.kickoff_at.to_i, @contest.starts_in_at.to_i
    assert_equal first_game.kickoff_at.to_i, @contest.onchain_params[:lock_timestamp]
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
    @contest.slate.update!(starts_at: nil)
    @contest.slate.slate_matchups.update_all(game_slug: nil)
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

  # --- live? + games_by_phase (active contest page) ---

  test "live? is true once locked and not settled" do
    @contest.update!(starts_at: 1.minute.ago, status: "open")
    assert @contest.live?
  end

  test "live? is false before the lock time" do
    @contest.update!(starts_at: 1.hour.from_now, status: "open")
    assert_not @contest.live?
  end

  test "live? is false once settled" do
    @contest.update!(starts_at: 1.hour.ago, status: "settled")
    assert_not @contest.live?
  end

  test "games_by_phase buckets games by status + kickoff" do
    active   = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b", kickoff_at: 1.hour.ago,      status: "scheduled")
    upcoming = Game.create!(home_team_slug: "team-c", away_team_slug: "team-d", kickoff_at: 1.day.from_now,  status: "scheduled")
    done     = Game.create!(home_team_slug: "team-e", away_team_slug: "team-f", kickoff_at: 2.hours.ago,     status: "completed")
    slate_matchups(:m1).update!(game_slug: active.slug)
    slate_matchups(:m3).update!(game_slug: upcoming.slug)
    slate_matchups(:m5).update!(game_slug: done.slug)

    phases = @contest.games_by_phase
    assert_includes phases[:active],    active
    assert_includes phases[:upcoming],  upcoming
    assert_includes phases[:completed], done
    assert_not_includes phases[:active], upcoming
  end
end
