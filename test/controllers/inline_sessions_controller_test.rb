require "test_helper"

class InlineSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:sam)
  end

  test "create succeeds with valid email + password (JSON)" do
    post inline_login_path,
      params: { email: @user.email, password: "password" },
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert_equal @user.id, json["user"]["id"]
    assert_equal @user.display_name, json["user"]["name"]
    assert_includes [true, false], json["user"]["has_wallet"]
  end

  test "create returns 401 on wrong password" do
    post inline_login_path,
      params: { email: @user.email, password: "wrong-password" },
      as: :json

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_not json["success"]
    assert_match(/invalid/i, json["error"])
  end

  test "create returns 401 on unknown email" do
    post inline_login_path,
      params: { email: "nobody@nowhere.test", password: "password" },
      as: :json

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_not json["success"]
    assert_match(/invalid/i, json["error"])
  end
end
