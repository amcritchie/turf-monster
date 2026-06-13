require "test_helper"

# Entry-time age gate (ENABLE_AGE_GATE) — the DOB verification endpoint.
# Recomputes age server-side against the DETECTED state (geo_override here),
# stamps date_of_birth + age_attested_at on success, never trusts the client.
class AgeVerificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      name: "Age Andy", username: "aa-#{SecureRandom.hex(2)}",
      email: "aa-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current
    )
  end

  test "requires login" do
    post age_verify_path, params: { year: 2000, month: 1, day: 1 }, as: :json
    assert_response :unauthorized
  end

  test "stamps date_of_birth + age_attested_at for an of-age user" do
    log_in_as(@user)
    assert_nil @user.reload.age_attested_at

    post age_verify_path, params: { year: 2000, month: 3, day: 15 }, as: :json
    assert_response :success
    assert JSON.parse(response.body)["verified"]

    @user.reload
    assert_equal Date.new(2000, 3, 15), @user.date_of_birth
    assert @user.age_attested_at.present?
  end

  test "rejects an underage user and stamps nothing" do
    log_in_as(@user)
    post age_verify_path, params: { year: (Date.current.year - 16), month: 1, day: 1 }, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_not body["verified"]
    assert_equal 18, body["minimum_age"]
    assert_nil @user.reload.age_attested_at
  end

  test "rejects a malformed date" do
    log_in_as(@user)
    post age_verify_path, params: { year: 2000, month: 13, day: 40 }, as: :json
    assert_response :unprocessable_entity
    assert_not JSON.parse(response.body)["verified"]
  end
end
