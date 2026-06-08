require "test_helper"

# Entries::OnchainReconcileJob wraps the reconciler so a JOB-level fault (a
# find_by / sweep-enumeration error — distinct from the per-entry faults the
# reconciler already rescues into :error) is captured to ErrorLog AND re-raised
# so Sidekiq's retry still fires. (PR #115 review N2.)
class Entries::OnchainReconcileJobTest < ActiveJob::TestCase
  test "captures a sweep-path job fault to ErrorLog and re-raises for Sidekiq retry" do
    boom = ->(*, **) { raise StandardError, "simulated sweep fault" }

    assert_difference -> { ErrorLog.count }, 1 do
      Entries::OnchainReconciler.stub :run, boom do
        assert_raises(StandardError) { Entries::OnchainReconcileJob.new.perform }
      end
    end

    assert_match "simulated sweep fault", ErrorLog.order(:id).last.message
  end

  test "captures a single-entry job fault with entry + contest context and re-raises" do
    contest = contests(:one)
    contest.update!(onchain_contest_id: "onchain-job", season_id: 1, starts_at: 1.day.from_now)
    entry = contest.entries.create!(user: users(:sam), status: :cart)

    boom = ->(*, **) { raise StandardError, "simulated job fault" }

    assert_difference -> { ErrorLog.count }, 1 do
      Entries::OnchainReconciler.stub :reconcile_entry, boom do
        assert_raises(StandardError) { Entries::OnchainReconcileJob.new.perform(entry.id) }
      end
    end

    log = ErrorLog.order(:id).last
    assert_equal entry, log.target
    assert_equal entry.slug, log.target_name
    assert_equal contest, log.parent
    assert_equal contest.slug, log.parent_name
  end

  test "a missing entry_id is a logged no-op — no error, no ErrorLog" do
    assert_no_difference -> { ErrorLog.count } do
      assert_nothing_raised { Entries::OnchainReconcileJob.new.perform(999_999) }
    end
  end
end
