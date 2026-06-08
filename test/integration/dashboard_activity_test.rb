require "test_helper"

# The admin dashboard's "Users by recent session" relies on last_seen_at, which
# ApplicationController#touch_last_seen stamps (throttled) on authenticated
# requests, and User.by_recent_session orders by.
class DashboardActivityTest < ActionDispatch::IntegrationTest
  setup { @admin = users(:alex) }

  test "an authenticated request stamps last_seen_at" do
    @admin.update_column(:last_seen_at, nil)
    log_in_as(@admin)
    get admin_dashboard_path
    assert_response :success
    assert_not_nil @admin.reload.last_seen_at
  end

  test "last_seen_at is throttled within the window" do
    log_in_as(@admin)
    get admin_dashboard_path
    first = @admin.reload.last_seen_at
    assert_not_nil first
    travel 1.minute do
      get admin_dashboard_path
      assert_equal first.to_i, @admin.reload.last_seen_at.to_i, "should not rewrite within the throttle window"
    end
  end

  test "last_seen_at refreshes past the throttle window" do
    log_in_as(@admin)
    get admin_dashboard_path
    first = @admin.reload.last_seen_at
    travel(ApplicationController::LAST_SEEN_THROTTLE + 1.minute) do
      get admin_dashboard_path
      assert @admin.reload.last_seen_at > first, "should refresh past the throttle window"
    end
  end

  test "by_recent_session orders most-recently-seen first, never-seen last" do
    older = users(:jordan); older.update_column(:last_seen_at, 2.hours.ago)
    newer = users(:sam);    newer.update_column(:last_seen_at, 5.minutes.ago)
    never = users(:alex);   never.update_column(:last_seen_at, nil)
    ordered = User.by_recent_session.to_a
    assert_operator ordered.index(newer), :<, ordered.index(older), "newer before older"
    assert_operator ordered.index(older), :<, ordered.index(never), "seen before never-seen"
  end
end
