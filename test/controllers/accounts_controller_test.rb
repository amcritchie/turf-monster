require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alex = users(:alex)
  end

  test "show requires login" do
    get account_path
    assert_redirected_to login_path
  end

  test "save_profile redirects first-time username setters to tokens buy" do
    user = User.create!(email: "newbie@mcritchie.studio", password: "password")
    log_in_as user
    post save_profile_account_path, params: { user: { username: "newbie" } }
    assert_redirected_to tokens_buy_path
  end

  test "save_profile redirects subsequent username updates to root" do
    log_in_as @alex
    post save_profile_account_path, params: { user: { username: "alex_renamed" } }
    assert_redirected_to root_path
  end

  test "show renders for logged in user" do
    log_in_as @alex
    get account_path
    assert_response :success
  end

  test "update changes name" do
    log_in_as @alex
    patch account_path, params: { user: { name: "New Name" } }
    assert_redirected_to account_path
    @alex.reload
    assert_equal "New Name", @alex.name
  end

  test "unlink_google clears provider and uid" do
    @alex.update!(provider: "google_oauth2", uid: "12345")
    log_in_as @alex
    post unlink_google_account_path
    assert_redirected_to account_path
    @alex.reload
    assert_nil @alex.provider
    assert_nil @alex.uid
  end

  test "change_password updates password" do
    log_in_as @alex
    post change_password_account_path, params: {
      current_password: "password",
      new_password: "newpassword",
      new_password_confirmation: "newpassword"
    }
    assert_redirected_to account_path
    @alex.reload
    assert @alex.authenticate("newpassword")
  end

  test "change_password fails with wrong current password" do
    log_in_as @alex
    post change_password_account_path, params: {
      current_password: "wrongpassword",
      new_password: "newpassword",
      new_password_confirmation: "newpassword"
    }
    assert_response :unprocessable_entity
  end

  test "update_level updates user level" do
    log_in_as @alex
    patch update_level_account_path, params: { seeds_total: 250 }, as: :json
    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert_equal 3, json["level"]
    assert_equal 3, @alex.reload.level
  end

  test "update_level requires login" do
    patch update_level_account_path, params: { seeds_total: 100 }, as: :json
    assert_response :redirect
  end
end
