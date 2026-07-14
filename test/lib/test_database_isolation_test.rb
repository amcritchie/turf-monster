# frozen_string_literal: true

require "test_helper"
require "open3"

# config/database.yml's test block MUST honour TEST_DATABASE_URL.
#
# THE HAZARD THIS PINS (live, 2026-07-14). `TEST_DATABASE_URL` is a HAND-ROLLED seam: it
# does nothing unless this app's config/database.yml actually reads it. turf-monster's test
# block was a bare `database: turf_monster_test` with no `url:` key — so when
# mcritchie-studio's bin/agent-worktree gave a turf desk its own test database and pinned
# it (.env.test.local, TEST_DATABASE_URL=…/turf_monster_test_<slug>), THE PIN WAS INERT.
# Every turf desk resolved to the SHARED `turf_monster_test`, and `bin/full-suite-check`'s
# first lane — `db:test:purge` — DESTROYED the database the primary checkout, the release
# gate, and every other live turf desk were mid-suite against. Two turf desks were live when
# this was found.
#
# WHY THIS TEST ASSERTS THE PROPERTY, NOT THE SPELLING. Grepping database.yml for
# `url: <%= ENV["TEST_DATABASE_URL"] %>` would pass on a line that a later `<<: *default`
# override, a typo'd key, or a Rails change had rendered ineffective — it would assert the
# SPELLING of the fix, and the class of bug this comes from is exactly "a config that says
# the right thing and does not do it". So it BOOTS the app under a pinned TEST_DATABASE_URL
# and reads back the database Rails ACTUALLY resolves. Same doctrine as mcritchie-studio's
# DeskGuard and bin/release.rb's assert_private_gate_db!: ask the booted app.
#
# The probe reads `connection_db_config`, which does NOT open a connection — so no database
# named here is ever created, touched, or purged.
class TestDatabaseIsolationTest < ActiveSupport::TestCase
  PROBE = 'print "RESOLVED=#{ActiveRecord::Base.connection_db_config.database}\n"'
  SHARED = "turf_monster_test"
  PINNED = "turf_monster_test_isolation_probe"

  test "a pinned TEST_DATABASE_URL actually moves the test connection off the shared DB" do
    resolved = resolve("TEST_DATABASE_URL" => "postgresql://localhost/#{PINNED}")

    assert_equal PINNED, resolved,
                 "config/database.yml's `test:` block is IGNORING TEST_DATABASE_URL, so every agent " \
                 "worktree's isolated test DB is inert and its `db:test:purge` lands on the SHARED " \
                 "#{SHARED}. Restore `url: <%= ENV[\"TEST_DATABASE_URL\"] %>` to the test block."
  end

  test "an explicit pin wins over DATABASE_URL" do
    # A worktree exports DATABASE_URL at its seeded DEV database. If that won, the suite
    # would run — and db:test:purge would land — on the DEV data. An explicit `url:` in the
    # test block outranks DATABASE_URL, which is the whole reason the pin is a separate var.
    resolved = resolve(
      "DATABASE_URL" => "postgresql://localhost/turf_monster_development_probe",
      "TEST_DATABASE_URL" => "postgresql://localhost/#{PINNED}"
    )

    assert_equal PINNED, resolved
  end

  test "with no pin it still falls back to the shared test DB" do
    # The CI and plain-local shape: `url:` renders EMPTY and Rails falls back to `database:`.
    # The isolation seam must not change where an unpinned boot lands.
    assert_equal SHARED, resolve("TEST_DATABASE_URL" => "")
  end

  private

  # Boot a child Rails at RAILS_ENV=test under `overlay` and read back its database.
  def resolve(overlay)
    env = ENV.to_h.merge("RAILS_ENV" => "test").merge(overlay)
    # The parent suite is mid-run with its own env; neutralize the vars we are varying so a
    # leaked one cannot decide the answer, and let the overlay be the only difference.
    out, status = Open3.capture2e(env, "bin/rails", "runner", PROBE, chdir: Rails.root.to_s)
    assert status.success?, "probe boot failed:\n#{out}"

    out[/RESOLVED=(.*)$/, 1].to_s.strip
  end
end
