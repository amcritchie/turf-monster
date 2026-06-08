require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @user  = users(:jordan)
    # Real users always have a slug (Sluggable); fixtures don't, and the "Act as"
    # button needs one. Backfill so the index renders.
    User.where(slug: nil).find_each { |u| u.update_column(:slug, "user-#{u.id}") }
  end

  test "index requires admin" do
    log_in_as(@user)
    get admin_users_path
    assert_response :redirect
  end

  test "every sort option renders" do
    log_in_as(@admin)
    Admin::UsersController::SORTS.each_key do |sort|
      get admin_users_path(sort: sort)
      assert_response :success, "sort=#{sort} should render"
    end
  end

  test "default sort is last active, and an unknown sort falls back to it" do
    log_in_as(@admin)
    get admin_users_path # no param
    assert_select "a.bg-primary", text: "Last active" # the active pill is highlighted
    get admin_users_path(sort: "bogus")
    assert_select "a.bg-primary", text: "Last active"
  end

  test "seeds sort orders by the cached seed total desc" do
    @user.update_column(:seeds, 500)
    users(:sam).update_column(:seeds, 10)
    log_in_as(@admin)
    get admin_users_path(sort: "seeds")
    assert_response :success
    assert_operator response.body.index(@user.email), :<, response.body.index(users(:sam).email),
                    "higher-seed user should appear first"
  end

  test "shows the Level and Seeds columns" do
    @user.update_columns(level: 3, seeds: 250)
    log_in_as(@admin)
    get admin_users_path
    assert_select "th", text: "Level"
    assert_select "th", text: "Seeds"
    assert_match(/Lv&nbsp;3/, response.body)
  end
end
