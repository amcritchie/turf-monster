require "test_helper"

class ImpersonationLogTest < ActiveSupport::TestCase
  setup do
    @admin  = users(:alex)   # role: admin
    @target = users(:jordan) # non-admin
  end

  test "action enum maps enter:0 / exit:1" do
    assert_equal 0, ImpersonationLog.actions["enter"]
    assert_equal 1, ImpersonationLog.actions["exit"]

    enter = ImpersonationLog.create!(action: :enter, admin: @admin, target_user: @target)
    quit  = ImpersonationLog.create!(action: :exit,  admin: @admin, target_user: @target)
    assert enter.enter?
    assert quit.exit?
  end

  test "belongs_to admin and target_user resolve to User and are required" do
    log = ImpersonationLog.create!(action: :enter, admin: @admin, target_user: @target)
    assert_equal @admin,  log.admin
    assert_equal @target, log.target_user

    invalid = ImpersonationLog.new(action: :enter)
    assert_not invalid.valid?
    assert_includes invalid.errors[:admin], "must exist"
    assert_includes invalid.errors[:target_user], "must exist"
  end

  test "recent scope orders newest first" do
    older = ImpersonationLog.create!(action: :enter, admin: @admin, target_user: @target, created_at: 2.hours.ago)
    newer = ImpersonationLog.create!(action: :exit,  admin: @admin, target_user: @target, created_at: 1.minute.ago)
    assert_equal [newer.id, older.id], ImpersonationLog.recent.pluck(:id)
  end

  test "created_at is auto-set and there is no updated_at column (audit convention)" do
    log = ImpersonationLog.create!(action: :enter, admin: @admin, target_user: @target)
    assert_not_nil log.created_at
    assert_not ImpersonationLog.column_names.include?("updated_at"),
               "audit rows are immutable — no updated_at (mirrors OutboundRequest)"
  end

  test "reason is optional and stored when present" do
    log = ImpersonationLog.create!(action: :exit, admin: @admin, target_user: @target, reason: "logout")
    assert_equal "logout", log.reason
    assert ImpersonationLog.create!(action: :enter, admin: @admin, target_user: @target).valid?
  end
end
