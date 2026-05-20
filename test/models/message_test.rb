require "test_helper"

class MessageTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @user    = users(:jordan)
    @admin   = users(:alex)
  end

  test "valid with a contest, user, and body" do
    assert Message.new(contest: @contest, user: @user, body: "hello").valid?
  end

  test "body is required" do
    message = Message.new(contest: @contest, user: @user, body: "   ")
    assert_not message.valid?
    assert_includes message.errors[:body], "can't be blank"
  end

  test "body cannot exceed the max length" do
    message = Message.new(contest: @contest, user: @user, body: "x" * (Message::BODY_MAX_LENGTH + 1))
    assert_not message.valid?
  end

  test "body is stripped before validation" do
    message = Message.create!(contest: @contest, user: @user, body: "  spaced out  ")
    assert_equal "spaced out", message.body
  end

  test "visible scope excludes hidden messages" do
    shown  = Message.create!(contest: @contest, user: @user, body: "shown")
    hidden = Message.create!(contest: @contest, user: @user, body: "hidden")
    hidden.hide!(@admin)

    assert_includes Message.visible, shown
    assert_not_includes Message.visible, hidden
  end

  test "hide! records the hiding admin and a timestamp" do
    message = Message.create!(contest: @contest, user: @user, body: "moderate me")
    message.hide!(@admin)

    assert message.hidden?
    assert_equal @admin.id, message.hidden_by_id
    assert_not_nil message.hidden_at
  end

  test "recent_for returns visible messages oldest-first" do
    older   = Message.create!(contest: @contest, user: @user, body: "older", created_at: 2.minutes.ago)
    newer   = Message.create!(contest: @contest, user: @user, body: "newer", created_at: 1.minute.ago)
    removed = Message.create!(contest: @contest, user: @user, body: "removed")
    removed.hide!(@admin)

    result = Message.recent_for(@contest)

    assert_not_includes result, removed
    assert_operator result.index(older), :<, result.index(newer)
  end
end
