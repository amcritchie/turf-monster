require "test_helper"
require "minitest/mock"

# BL5 (Stage 3 audit): #grade! tie-payout splitting. The ranking + payout
# math at contest.rb:184-217 handles ties via spanned-rank summation and
# integer remainder distribution. These pin down the easy-to-miss money-
# bug cases on the "standard" tier (payouts 1=>$300, 2-5=>$50).
class ContestGradeTiePayoutsTest < ActiveSupport::TestCase
  setup do
    @creator = users(:alex)
    @slate = slates(:one)
    @contest = Contest.create!(
      name: "Standard tie test #{SecureRandom.hex(2)}",
      slate: @slate,
      rank: 9000 + rand(900),
      contest_type: "standard",
      starts_at: 1.hour.from_now,
      user: @creator,
      status: "open",
      max_entries: 29
    )
  end

  test "two entries tied for 1st split spanned ranks 1+2 evenly ($350 → $175 each)" do
    e1 = make_active_entry(score: 100.0)
    e2 = make_active_entry(score: 100.0)
    e3 = make_active_entry(score: 50.0)

    @contest.stub :score_entries!, nil do
      @contest.grade!
    end

    [e1, e2, e3].each(&:reload)
    assert_equal 1, e1.rank
    assert_equal 1, e2.rank
    assert_equal 3, e3.rank
    assert_equal 17_500, e1.payout_cents
    assert_equal 17_500, e2.payout_cents
    assert_equal 50_00, e3.payout_cents
  end

  test "three-way tie for 1st spans ranks 1+2+3, splits $400 with remainder to earliest" do
    e1 = make_active_entry(score: 100.0)
    e2 = make_active_entry(score: 100.0)
    e3 = make_active_entry(score: 100.0)
    e4 = make_active_entry(score: 50.0)

    @contest.stub :score_entries!, nil do
      @contest.grade!
    end

    [e1, e2, e3, e4].each(&:reload)
    assert_equal 1, e1.rank
    assert_equal 1, e2.rank
    assert_equal 1, e3.rank
    assert_equal 4, e4.rank
    # 400_00 / 3 = 13333, remainder 1 → e1 gets +1
    assert_equal 13_334, e1.payout_cents
    assert_equal 13_333, e2.payout_cents
    assert_equal 13_333, e3.payout_cents
    assert_equal 400_00, e1.payout_cents + e2.payout_cents + e3.payout_cents
    assert_equal 50_00, e4.payout_cents
  end

  test "five-way tie for 1st spans entire standard schedule ($500 → $100 each)" do
    entries_tied = 5.times.map { make_active_entry(score: 100.0) }

    @contest.stub :score_entries!, nil do
      @contest.grade!
    end

    entries_tied.each(&:reload)
    assert entries_tied.all? { |e| e.rank == 1 }
    entries_tied.each { |e| assert_equal 100_00, e.payout_cents }
    assert_equal 500_00, entries_tied.sum(&:payout_cents)
  end

  private

  def make_active_entry(score:)
    user = User.create!(email: "tied_#{SecureRandom.hex(4)}@example.com")
    Entry.create!(user: user, contest: @contest, status: "active", score: score)
  end
end

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

  # ── name/slug decouple (epic Part A, 2026-06-02) ──────────────────────────
  # Names repeat (branded); slug is the globally-unique, manually-set key that
  # seeds the on-chain PDA + every URL. Sluggable's auto-overwrite is neutralized.

  test "an explicit slug is NOT overwritten from the name on save (decoupled)" do
    c = Contest.create!(name: "Branded Name", slug: "hand-picked-slug",
                        slate: slates(:one), status: :open, contest_type: "small")
    assert_equal "hand-picked-slug", c.slug
    # Rename — slug (and therefore the on-chain PDA) must stay put.
    c.update!(name: "A Totally Different Name")
    assert_equal "hand-picked-slug", c.reload.slug
  end

  test "two contests with the SAME name but DIFFERENT slugs both save (no name uniqueness)" do
    a = Contest.create!(name: "World Cup Group A", slug: "wc-group-a-morning",
                        slate: slates(:one), status: :open, contest_type: "small")
    b = Contest.create!(name: "World Cup Group A", slug: "wc-group-a-evening",
                        slate: slates(:one), status: :open, contest_type: "small")
    assert a.persisted?
    assert b.persisted?
    assert_equal a.name, b.name
    assert_not_equal a.slug, b.slug
  end

  test "duplicate slug is rejected" do
    Contest.create!(name: "First", slug: "shared-slug",
                    slate: slates(:one), status: :open, contest_type: "small")
    dup = Contest.new(name: "Second", slug: "shared-slug",
                      slate: slates(:one), status: :open, contest_type: "small")
    assert_not dup.valid?
    assert_includes dup.errors[:slug], "has already been taken"
  end

  test "slug rejects spaces, uppercase, and symbols" do
    ["has spaces", "HasUpper", "has_underscore", "has!bang", "-leading", "trailing-",
     "double--hyphen"].each do |bad|
      c = Contest.new(name: "Fmt", slug: bad, slate: slates(:one), status: :open, contest_type: "small")
      assert_not c.valid?, "expected slug #{bad.inspect} to be invalid"
      assert c.errors[:slug].any?, "expected a slug format error for #{bad.inspect}"
    end
    # A valid url-safe slug passes the format check.
    ok = Contest.new(name: "Fmt", slug: "world-cup-group-a-2026", slate: slates(:one), status: :open, contest_type: "small")
    ok.valid?
    assert_empty ok.errors[:slug]
  end

  test "name over 96 bytes is rejected (UTF-8 bytesize, not char length)" do
    c = Contest.new(name: "a" * 97, slug: "long-name", slate: slates(:one), status: :open, contest_type: "small")
    assert_not c.valid?
    assert c.errors[:name].any?
    # Exactly 96 bytes is allowed.
    ok = Contest.new(name: "a" * 96, slug: "name-at-limit", slate: slates(:one), status: :open, contest_type: "small")
    ok.valid?
    assert_empty ok.errors[:name]
  end

  test "name byte limit counts UTF-8 bytes, not characters" do
    # "é" is 2 bytes in UTF-8. 49 of them = 98 bytes (> 96) but only 49 chars.
    multibyte = "é" * 49
    assert_equal 49, multibyte.length
    assert_equal 98, multibyte.bytesize
    c = Contest.new(name: multibyte, slug: "multibyte-name", slate: slates(:one), status: :open, contest_type: "small")
    assert_not c.valid?, "a 98-byte (49-char) name must be rejected by the bytesize cap"
    assert c.errors[:name].any?
  end

  test "slug over 64 bytes is rejected" do
    over = ("a" * 32) + "-" + ("b" * 32) # 65 bytes
    assert_equal 65, over.bytesize
    c = Contest.new(name: "Long Slug", slug: over, slate: slates(:one), status: :open, contest_type: "small")
    assert_not c.valid?
    assert c.errors[:slug].any?
  end

  test "Contest.create!(name:) without a slug backfills a unique slug from the name" do
    a = Contest.create!(name: "Backfill Me", slate: slates(:one), status: :open, contest_type: "small")
    assert_equal "backfill-me", a.slug
    # Same name again → de-duped, not a collision.
    b = Contest.create!(name: "Backfill Me", slate: slates(:one), status: :open, contest_type: "small")
    assert b.persisted?
    assert_not_equal a.slug, b.slug
    assert_match(/\Abackfill-me(-[0-9a-f]{4})?\z/, b.slug)
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
