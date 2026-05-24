require "test_helper"

class InlineRegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "create succeeds with valid email + password (JSON)" do
    assert_difference "User.count", 1 do
      post inline_signup_path,
        params: { email: "inline-new@mcritchie.studio", password: "password" },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    user = User.find_by(email: "inline-new@mcritchie.studio")
    assert_equal user.id, json["user"]["id"]
    assert user.username.present?, "signup should auto-assign a username"
    assert_equal user.id, session[:turf_user_id]
  end

  test "create renders the logged-in navbar as HTML in the JSON payload" do
    # Regression: render_to_string(partial: 'layouts/navbar') without an
    # explicit formats:[:html] defaults to the request format (JSON) and
    # 500s with ActionView::MissingTemplate looking for _navbar.json.erb.
    post inline_signup_path,
      params: { email: "navbar-test@mcritchie.studio", password: "password" },
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert json["navbar_html"].present?, "navbar_html should be returned"
    assert_match(/<header/, json["navbar_html"], "navbar should render as HTML (not error / empty)")
  end

  test "create returns 422 on duplicate email" do
    User.create!(email: "dup@mcritchie.studio", password: "password", password_confirmation: "password")

    assert_no_difference "User.count" do
      post inline_signup_path,
        params: { email: "dup@mcritchie.studio", password: "password" },
        as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_not json["success"]
    assert json["error"].present?
  end
end
