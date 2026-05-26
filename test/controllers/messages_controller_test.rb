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
                         password: "password", role: "admin")
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
end
