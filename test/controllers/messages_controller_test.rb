require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @contest  = contests(:one)
    @entrant  = users(:jordan)  # non-admin, has an active entry in :one
    @admin    = users(:alex)    # admin
    @outsider = users(:sam)     # non-admin, no entry in :one
  end

  test "an entrant can post a message" do
    log_in_as(@entrant)
    assert_difference -> { @contest.messages.count }, 1 do
      post contest_messages_url(@contest), params: { message: { body: "let's go" } }, as: :json
    end
    assert_response :success
  end

  test "an admin can post without having entered" do
    admin = User.create!(name: "Mod", username: "modtest", email: "mod@mcritchie.studio",
                         role: "admin")
    log_in_as(admin)
    assert_difference -> { @contest.messages.count }, 1 do
      post contest_messages_url(@contest), params: { message: { body: "admin moderating" } }, as: :json
    end
    assert_response :success
  end

  test "a non-entrant cannot post" do
    log_in_as(@outsider)
    assert_no_difference -> { @contest.messages.count } do
      post contest_messages_url(@contest), params: { message: { body: "sneaking in" } }, as: :json
    end
    assert_response :forbidden
  end

  test "a guest cannot post" do
    assert_no_difference -> { @contest.messages.count } do
      post contest_messages_url(@contest), params: { message: { body: "anon" } }, as: :json
    end
    # JSON requests get a clean 401 (authedFetch surfaces this as the
    # login modal). HTML navigations still redirect.
    assert_response :unauthorized
  end

  test "a blank message is rejected" do
    log_in_as(@entrant)
    assert_no_difference -> { @contest.messages.count } do
      post contest_messages_url(@contest), params: { message: { body: "   " } }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "an over-long message is rejected" do
    log_in_as(@entrant)
    assert_no_difference -> { @contest.messages.count } do
      post contest_messages_url(@contest),
           params: { message: { body: "x" * (Message::BODY_MAX_LENGTH + 1) } }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "posting is blocked when chat is disabled" do
    @contest.update!(chat_enabled: false)
    log_in_as(@entrant)
    assert_no_difference -> { @contest.messages.count } do
      post contest_messages_url(@contest), params: { message: { body: "hello" } }, as: :json
    end
    assert_response :forbidden
  end

  test "an admin can hide a message" do
    message = @contest.messages.create!(user: @entrant, body: "moderate me")
    log_in_as(@admin)
    delete contest_message_url(@contest, message), as: :json
    assert_response :success
    assert message.reload.hidden?
  end

  test "a non-admin cannot hide a message" do
    message = @contest.messages.create!(user: @entrant, body: "leave it")
    log_in_as(@entrant)
    delete contest_message_url(@contest, message), as: :json
    assert_response :forbidden
    assert_not message.reload.hidden?
  end

  test "the per-user rate limit returns 429" do
    log_in_as(@entrant)
    5.times do |i|
      post contest_messages_url(@contest), params: { message: { body: "message #{i}" } }, as: :json
    end
    post contest_messages_url(@contest), params: { message: { body: "one too many" } }, as: :json
    assert_response :too_many_requests
  end

  # === Emoji reactions ===================================================

  test "an entrant can add a reaction" do
    message = @contest.messages.create!(user: @entrant, body: "react to me")
    log_in_as(@entrant)
    assert_difference -> { message.reactions.count }, 1 do
      post toggle_reaction_contest_message_url(@contest, message), params: { emoji: "❤️" }, as: :json
    end
    assert_response :success
    assert_equal true, response.parsed_body["reacted"]
  end

  test "reacting with the same emoji again toggles it off" do
    message = @contest.messages.create!(user: @entrant, body: "toggle me")
    message.reactions.create!(user: @entrant, emoji: "❤️")
    log_in_as(@entrant)
    assert_difference -> { message.reactions.count }, -1 do
      post toggle_reaction_contest_message_url(@contest, message), params: { emoji: "❤️" }, as: :json
    end
    assert_response :success
    assert_equal false, response.parsed_body["reacted"]
  end

  test "the contest sport emoji is an accepted reaction" do
    message = @contest.messages.create!(user: @entrant, body: "goal!")
    log_in_as(@entrant)
    post toggle_reaction_contest_message_url(@contest, message),
         params: { emoji: @contest.sport_emoji }, as: :json
    assert_response :success
  end

  test "an unsupported emoji is rejected" do
    message = @contest.messages.create!(user: @entrant, body: "nope")
    log_in_as(@entrant)
    assert_no_difference -> { message.reactions.count } do
      post toggle_reaction_contest_message_url(@contest, message), params: { emoji: "🦄" }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "a non-entrant cannot react" do
    message = @contest.messages.create!(user: @entrant, body: "hands off")
    log_in_as(@outsider)
    assert_no_difference -> { message.reactions.count } do
      post toggle_reaction_contest_message_url(@contest, message), params: { emoji: "❤️" }, as: :json
    end
    assert_response :forbidden
  end

  test "a guest cannot react" do
    message = @contest.messages.create!(user: @entrant, body: "anon react")
    assert_no_difference -> { message.reactions.count } do
      post toggle_reaction_contest_message_url(@contest, message), params: { emoji: "❤️" }, as: :json
    end
    assert_response :unauthorized
  end

  test "reactions are blocked when chat is disabled" do
    @contest.update!(chat_enabled: false)
    message = @contest.messages.create!(user: @entrant, body: "closed")
    log_in_as(@entrant)
    assert_no_difference -> { message.reactions.count } do
      post toggle_reaction_contest_message_url(@contest, message), params: { emoji: "❤️" }, as: :json
    end
    assert_response :forbidden
  end

  test "reacting to a hidden message returns not found" do
    message = @contest.messages.create!(user: @entrant, body: "hidden")
    message.hide!(@admin)
    log_in_as(@entrant)
    post toggle_reaction_contest_message_url(@contest, message), params: { emoji: "❤️" }, as: :json
    assert_response :not_found
  end
end
