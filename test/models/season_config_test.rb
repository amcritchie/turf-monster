require "test_helper"

class SeasonConfigTest < ActiveSupport::TestCase
  # Helper — build a Contest in the given status without going through the
  # on-chain after_create callback (skipped automatically in test env per
  # Contest#skip_onchain_callback_active?). Older fixtures don't cover all
  # statuses, and the fallback chain needs at least 1 open + sometimes a
  # locked or settled one to exercise.
  def build_contest(name, status:, created_at: Time.current)
    Contest.create!(
      name: name, status: status, contest_type: "small",
      entry_fee_cents: 1900, max_entries: 5, slate: slates(:one),
      starts_at: 1.week.from_now, rank: 100, created_at: created_at
    )
  end

  test "main_contest returns nil when nothing is open and no explicit pick" do
    # Wipe contests so neither the explicit nor the open-fallback path can hit.
    Entry.delete_all
    Contest.delete_all
    assert_nil SeasonConfig.main_contest
  end

  test "main_contest_explicit returns the admin's raw pick regardless of status" do
    contest = build_contest("Explicit Pick", status: :locked)
    SeasonConfig.set_main_contest!(contest)
    # Even though it's locked (not open), the explicit getter returns it.
    assert_equal contest, SeasonConfig.main_contest_explicit
  end

  test "main_contest returns the explicit pick when it is open" do
    contest = build_contest("Open Pick", status: :open)
    SeasonConfig.set_main_contest!(contest)
    assert_equal contest, SeasonConfig.main_contest
  end

  test "main_contest masks a locked explicit pick and falls back to most-recent open" do
    Entry.delete_all
    Contest.delete_all
    locked = build_contest("Locked Pick", status: :locked, created_at: 2.days.ago)
    older  = build_contest("Older Open",  status: :open,   created_at: 3.days.ago)
    newer  = build_contest("Newer Open",  status: :open,   created_at: 1.day.ago)
    SeasonConfig.set_main_contest!(locked)

    assert_equal locked, SeasonConfig.main_contest_explicit
    assert_equal newer,  SeasonConfig.main_contest,
                 "fallback should pick the most recently created OPEN contest"
    refute_equal older, SeasonConfig.main_contest
  end

  test "main_contest falls back when nothing is explicitly set" do
    Entry.delete_all
    Contest.delete_all
    older = build_contest("Older Open", status: :open, created_at: 2.days.ago)
    newer = build_contest("Newer Open", status: :open, created_at: 1.day.ago)
    SeasonConfig.set_main_contest!(nil)

    assert_nil   SeasonConfig.main_contest_explicit
    assert_equal newer, SeasonConfig.main_contest
    refute_equal older, SeasonConfig.main_contest
  end

  test "set_main_contest! accepts a Contest" do
    c = build_contest("Accepts Object", status: :open)
    SeasonConfig.set_main_contest!(c)
    assert_equal c.id, SeasonConfig.current.main_contest_id
  end

  test "set_main_contest! accepts an integer id" do
    c = build_contest("Accepts Id", status: :open)
    SeasonConfig.set_main_contest!(c.id)
    assert_equal c.id, SeasonConfig.current.main_contest_id
  end

  test "set_main_contest! accepts nil to clear" do
    c = build_contest("Initial Pick", status: :open)
    SeasonConfig.set_main_contest!(c)
    assert_equal c.id, SeasonConfig.current.main_contest_id

    SeasonConfig.set_main_contest!(nil)
    assert_nil SeasonConfig.current.main_contest_id
  end
end
