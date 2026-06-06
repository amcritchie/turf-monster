require "test_helper"

# Admin::ScoringController — operator goal-entry console (/admin/scoring).
class Admin::ScoringControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @user  = users(:sam)
  end

  test "index redirects non-admins" do
    log_in_as(@user)
    get admin_scoring_path
    assert_response :redirect
  end

  test "index renders for an admin and lists fixtures that belong to a slate" do
    # Wire a fixture game into a slate matchup so the console has something to list.
    game = games(:past_game)
    slate_matchups(:m1).update!(game_slug: game.slug)

    log_in_as(@admin)
    get admin_scoring_path

    assert_response :success
    assert_select "h2", /Goal Console/
    # The game renders with its inline scorer config + a goal-entry button per team.
    assert_select "script#scorer-cfg-#{game.slug}", 1
    assert_select "div[x-data=?]", "gameScorer('scorer-cfg-#{game.slug}')"
  end
end
