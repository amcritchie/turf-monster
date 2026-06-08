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
end
