require "test_helper"

class ContestsHelperTest < ActionView::TestCase
  include ContestsHelper

  setup do
    @contest = contests(:one)
    @owner   = users(:sam)
    @other   = users(:jordan)
    @admin   = users(:alex)
    @entry   = @contest.entries.create!(user: @owner, status: :active)
    @admin_view = nil
  end

  # --- picks_visible_for? ---

  test "picks are visible to the entry owner while contest is open" do
    stub_current_user(@owner)
    assert picks_visible_for?(@entry)
  end

  test "picks are hidden from other users while contest is open" do
    stub_current_user(@other)
    assert_not picks_visible_for?(@entry)
  end

  test "picks are hidden from guests while contest is open" do
    stub_current_user(nil)
    assert_not picks_visible_for?(@entry)
  end

  test "picks are visible to admin via /admin URL override" do
    stub_current_user(@admin)
    @admin_view = true
    assert picks_visible_for?(@entry)
  end

  test "admin without @admin_view still respects ownership rules" do
    stub_current_user(@admin)
    @admin_view = nil
    # Admin user, but not on /admin URL → treated like any non-owner.
    assert_not picks_visible_for?(@entry)
  end

  test "picks are visible to everyone once contest is locked" do
    @contest.update!(status: "locked")
    stub_current_user(@other)
    assert picks_visible_for?(@entry)
  end

  test "picks are visible to everyone once contest is settled" do
    @contest.update!(status: "settled")
    stub_current_user(@other)
    assert picks_visible_for?(@entry)
  end

  # --- contest_debug_entries ---

  test "contest_debug_entries strips selections from hidden entries" do
    stub_current_user(@other)
    json = contest_debug_entries([@entry])
    assert_equal 1, json.size
    assert_not json[0].key?("selections"), "selections leaked while contest open"
    assert json[0].key?("user"), "user payload should remain for context"
  end

  test "contest_debug_entries includes selections for the entry owner" do
    stub_current_user(@owner)
    json = contest_debug_entries([@entry])
    assert json[0].key?("selections"), "owner should see their own selections"
  end

  private

  # ActionView::TestCase doesn't run controller callbacks, so we stub the
  # current_user / logged_in? helpers that picks_visible_for? consults.
  def stub_current_user(user)
    @_current_user = user
  end

  def current_user
    @_current_user
  end

  def logged_in?
    @_current_user.present?
  end
end
