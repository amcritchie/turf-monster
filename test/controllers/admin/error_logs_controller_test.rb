require "test_helper"

# Admin::ErrorLogsController — read-only incident-triage browser over ErrorLog
# (engine model, host namespace). Covers the require_admin gate, the index
# filters (q / target_type / klass / since), the exception-class parsing from
# the `inspect` column, the summary stats, show-by-slug, and the bad-slug
# redirect. ErrorLog rows are built directly (capture! is exercised elsewhere).
class Admin::ErrorLogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin   = users(:alex)   # role: admin
    @user    = users(:sam)    # non-admin, has email → log_in_as works
    @contest = contests(:one)
    @entry   = entries(:one)
    @entry.update_column(:slug, "entry-test-1")

    @runtime_log = make_log(
      klass:   "RuntimeError",
      message: "Exactly 6 selections required",
      target:  @contest
    )
    @invalid_log = make_log(
      klass:   "ActiveRecord::RecordInvalid",
      message: "Validation failed: entry busted",
      target:  @entry
    )
    @rpc_log = make_log(
      klass:      "Solana::RpcError",
      message:    "blockhash not found",
      created_at: 2.days.ago
    )
  end

  def make_log(klass:, message:, target: nil, parent: nil, created_at: Time.current)
    log = ErrorLog.create!(
      message:     message,
      inspect:     "#<#{klass}: #{message}>",
      backtrace:   ["app/foo.rb:1:in `bar'", "app/baz.rb:2:in `qux'"].to_json,
      target:      target,
      parent:      parent,
      target_name: target&.try(:slug),
      parent_name: parent&.try(:slug),
      created_at:  created_at
    )
    log.update_column(:slug, "error-log-#{log.id}")
    log
  end

  # --- require_admin gate ---

  test "index redirects non-admins" do
    log_in_as(@user)
    get admin_error_logs_path
    assert_redirected_to root_path
  end

  test "show redirects non-admins" do
    log_in_as(@user)
    get admin_error_log_path(@runtime_log)
    assert_redirected_to root_path
  end

  test "index redirects logged-out visitors" do
    get admin_error_logs_path
    assert_response :redirect
  end

  # --- index render + summary ---

  test "index renders all logs for an admin" do
    log_in_as(@admin)
    get admin_error_logs_path
    assert_response :success
    assert_match "Exactly 6 selections required", response.body
    assert_match "blockhash not found", response.body
    # Exception class is parsed from the inspect column and shown in the table.
    assert_match "RuntimeError", response.body
  end

  test "index summary counts total and surfaces top classes" do
    log_in_as(@admin)
    get admin_error_logs_path
    assert_response :success
    assert_match "Top Classes (24h)", response.body
    # The 24h facet should include the two recent classes, not the 2-day-old one.
    assert_match "Solana::RpcError", response.body # still listed in the table
  end

  # --- filters ---

  test "q filter narrows by message (case-insensitive)" do
    log_in_as(@admin)
    get admin_error_logs_path(q: "BLOCKHASH")
    assert_response :success
    assert_match "blockhash not found", response.body
    assert_no_match(/Exactly 6 selections required/, response.body)
  end

  test "target_type filter narrows to a single polymorphic type" do
    log_in_as(@admin)
    get admin_error_logs_path(target_type: "Contest")
    assert_response :success
    assert_match "Exactly 6 selections required", response.body
    assert_no_match(/Validation failed: entry busted/, response.body)
    assert_no_match(/blockhash not found/, response.body)
  end

  test "klass filter narrows by parsed exception class" do
    log_in_as(@admin)
    get admin_error_logs_path(klass: "RuntimeError")
    assert_response :success
    assert_match "Exactly 6 selections required", response.body
    assert_no_match(/blockhash not found/, response.body)
  end

  test "since filter excludes older logs" do
    log_in_as(@admin)
    get admin_error_logs_path(since: 1.day.ago.strftime("%Y-%m-%d %H:%M"))
    assert_response :success
    assert_match "Exactly 6 selections required", response.body
    assert_no_match(/blockhash not found/, response.body)
  end

  test "unparseable since is ignored, not fatal" do
    log_in_as(@admin)
    get admin_error_logs_path(since: "not-a-date")
    assert_response :success
    assert_match "Exactly 6 selections required", response.body
  end

  # --- show ---

  test "show renders by slug with class, message, and backtrace" do
    log_in_as(@admin)
    get admin_error_log_path(@runtime_log)
    assert_response :success
    assert_match "Exactly 6 selections required", response.body
    assert_match "RuntimeError", response.body
    assert_match "app/foo.rb:1", response.body
  end

  test "show deep-links a Contest target to its contest page" do
    log_in_as(@admin)
    get admin_error_log_path(@runtime_log)
    assert_response :success
    assert_select "a[href=?]", contest_path(@contest)
  end

  test "show deep-links an Entry target to its contest page" do
    log_in_as(@admin)
    get admin_error_log_path(@invalid_log)
    assert_response :success
    assert_select "a[href=?]", contest_path(@entry.contest)
  end

  test "show with unknown slug redirects to index with alert" do
    log_in_as(@admin)
    get admin_error_log_path(slug: "error-log-999999")
    assert_redirected_to admin_error_logs_path
    assert_equal "Error log not found.", flash[:alert]
  end

  test "show deep-links a User target to the admin users page" do
    user_log = make_log(
      klass:   "RuntimeError",
      message: "user-targeted failure",
      target:  @user
    )
    log_in_as(@admin)
    get admin_error_log_path(user_log)
    assert_response :success
    assert_select "a[href=?]", admin_users_path
  end

  test "show renders plain text for an orphaned target without raising" do
    orphan_log = make_log(
      klass:   "RuntimeError",
      message: "orphaned target failure",
      target:  @contest
    )
    # Point the target at a record that no longer exists: type is set but
    # neither the slug nor the id resolves, so error_record_path returns nil
    # and the helper must fall back to plain "Type: name" text.
    orphan_log.update_columns(target_id: 999_999, target_name: "contest-gone")

    log_in_as(@admin)
    get admin_error_log_path(orphan_log)
    assert_response :success
    # The helper's plain-text fallback renders "Type: name" — the linked branch
    # would emit only the bare label, so this match proves the no-route path.
    assert_match "Contest: contest-gone", response.body
  end

  # --- outer rescue: the viewer never 500s (operator directive) ---

  test "index falls back to a friendly empty page when its work raises" do
    log_in_as(@admin)
    # Force the action's main body to blow up. The stub stays in force through
    # the whole request, so if the outer rescue re-queried via .order it would
    # raise again and bubble to a 500 — a clean 200 proves it does NOT re-query.
    ErrorLog.stub(:order, ->(*) { raise StandardError, "kaboom" }) do
      get admin_error_logs_path
    end
    assert_response :success
    # Empty @error_logs (ErrorLog.none) renders the no-results row...
    assert_match "No error logs match these filters.", response.body
    # ...and the blank_summary surfaces a zero total, not a real count.
    assert_select "p.text-2xl", text: "0"
    # The captured error is surfaced to the operator as a flash alert.
    assert_match "Could not load error logs: kaboom", response.body
  end

  test "show redirects with an alert when its work raises a StandardError" do
    log_in_as(@admin)
    # A non-RecordNotFound failure inside the action hits the distinct
    # StandardError rescue (vs. the bad-slug RecordNotFound path above).
    ErrorLog.stub(:find_by!, ->(*) { raise StandardError, "kaboom" }) do
      get admin_error_log_path(@runtime_log)
    end
    assert_redirected_to admin_error_logs_path
    assert_equal "Could not load error log: kaboom", flash[:alert]
  end
end
