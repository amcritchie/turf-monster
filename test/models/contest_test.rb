require "test_helper"
require "minitest/mock"

class ContestTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @user = users(:sam)
  end

  test "pool_cents only counts active and complete entries" do
    # Fixtures have 2 active entries
    assert_equal 2 * @contest.entry_fee_cents, @contest.pool_cents

    # Cart entry should not count
    @contest.entries.create!(user: @user, status: :cart)
    assert_equal 2 * @contest.entry_fee_cents, @contest.pool_cents
  end

  test "picks_required returns 6" do
    assert_equal 6, @contest.picks_required
  end

  test "max_entries_per_user returns 3" do
    assert_equal 3, @contest.max_entries_per_user
  end

  test "slug is set on save" do
    @contest.save!
    assert_equal "test-contest", @contest.slug
  end

  test "lock_time_display formats starts_at" do
    @contest.starts_at = Time.new(2026, 6, 11, 12, 0, 0)
    assert_match(/Locks June 11, 2026/, @contest.lock_time_display)
  end

  test "lock_time_display returns TBD when no starts_at" do
    @contest.starts_at = nil
    assert_equal "TBD", @contest.lock_time_display
  end

  test "active_entry_count counts only active and complete entries" do
    assert_equal 2, @contest.active_entry_count
    @contest.entries.create!(user: @user, status: :cart)
    assert_equal 2, @contest.active_entry_count
  end

  test "season_id is bound to the active season on create (OPSEC-023)" do
    contest = Contest.create!(name: "Season Bind Test", slate: slates(:one), status: :open)
    assert_equal SeasonConfig.current_season_id, contest.season_id
  end

  test "onchain_params includes season_id (OPSEC-023)" do
    assert @contest.onchain_params.key?(:season_id)
  end

  # ── Test-scaffolding "micro" tier ($1 entry) — see AppFlags.test_scaffolding? ──

  test "micro tier is $1 entry, 9 max entries, $5/$1/$1 payouts" do
    config = Contest::FORMATS.fetch("micro")
    assert_equal 1_00, config[:entry_fee_cents]
    assert_equal 9,    config[:max_entries]
    assert_equal({ 1 => 5_00, 2 => 1_00, 3 => 1_00 }, config[:payouts])
  end

  test "a micro contest reports a $7 guaranteed prize" do
    contest = Contest.new(contest_type: "micro")
    assert_equal 7_00, contest.guaranteed_prize_cents
    assert_equal({ 1 => 5_00, 2 => 1_00, 3 => 1_00 }, contest.payouts)
  end

  test "selectable_formats hides the micro tier unless test scaffolding is on" do
    AppFlags.stub :test_scaffolding?, false do
      assert_not Contest.selectable_formats.key?("micro")
      assert Contest.selectable_formats.key?("standard")
    end
    AppFlags.stub :test_scaffolding?, true do
      assert Contest.selectable_formats.key?("micro")
    end
  end
end
