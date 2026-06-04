require "test_helper"

class ReactionTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @user    = users(:jordan)
    @message = @contest.messages.create!(user: @user, body: "let's go")
  end

  test "valid with an allowed emoji" do
    assert Reaction.new(message: @message, user: @user, emoji: "💯").valid?
    assert Reaction.new(message: @message, user: @user, emoji: "⚽").valid?  # sports
    assert Reaction.new(message: @message, user: @user, emoji: "👍").valid?  # picker
  end

  test "rejects an emoji outside the allowlist" do
    reaction = Reaction.new(message: @message, user: @user, emoji: "🦄")
    assert_not reaction.valid?
    assert_includes reaction.errors[:emoji], "is not included in the list"
  end

  test "rejects a blank emoji" do
    assert_not Reaction.new(message: @message, user: @user, emoji: "").valid?
  end

  test "a user can only use a given emoji once per message" do
    Reaction.create!(message: @message, user: @user, emoji: "💯")
    dup = Reaction.new(message: @message, user: @user, emoji: "💯")
    assert_not dup.valid?
    assert_includes dup.errors[:user_id], "has already been taken"
  end

  test "a user can use different emoji on the same message" do
    Reaction.create!(message: @message, user: @user, emoji: "💯")
    assert Reaction.new(message: @message, user: @user, emoji: "🐊").valid?
  end

  test "different users can use the same emoji on one message" do
    Reaction.create!(message: @message, user: @user, emoji: "💯")
    assert Reaction.new(message: @message, user: users(:alex), emoji: "💯").valid?
  end

  test "reactions are destroyed with their message" do
    Reaction.create!(message: @message, user: @user, emoji: "💯")
    assert_difference -> { Reaction.count }, -1 do
      @message.destroy
    end
  end
end
