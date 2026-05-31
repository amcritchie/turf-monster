require "test_helper"

class Contest::LiveBroadcastTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @contest = contests(:one) # turf_totals, slate :one
    @contest.update!(starts_at: 1.hour.ago, status: "open") # → live? true
    @game = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b",
                         kickoff_at: 30.minutes.ago, status: "scheduled")
    slate_matchups(:m1).update!(game_slug: @game.slug) # links the game to the contest's slate
  end

  test "goal_scored fires leaderboard + games + goal-feed broadcasts on the contest's live stream" do
    goal = Goal.new(game_slug: @game.slug, team_slug: "team-a")
    # Call the broadcaster directly (deterministic — doesn't depend on
    # after_create_commit firing under transactional fixtures). 3 broadcasts:
    # goal-feed append + leaderboard update + games update. If any partial fails
    # to render in broadcast context, that broadcast is rescued away and the
    # count drops below 3 — so this also guards the ivar→locals refactor.
    assert_turbo_stream_broadcasts([@contest, :live], count: 3) do
      Contest::LiveBroadcast.goal_scored(goal)
    end
  end

  test "affected_contests includes a live contest and excludes a settled one" do
    assert_includes Contest::LiveBroadcast.affected_contests(@game), @contest
    @contest.update!(status: "settled")
    assert_not_includes Contest::LiveBroadcast.affected_contests(@game), @contest
  end

  test "score_changed game_completed fires the FINAL feed + leaderboard + games" do
    assert_turbo_stream_broadcasts([@contest, :live], count: 3) do
      Contest::LiveBroadcast.score_changed(@game, event: :game_completed)
    end
  end

  test "score_changed goal_removed fires leaderboard + games (no toast feed)" do
    assert_turbo_stream_broadcasts([@contest, :live], count: 2) do
      Contest::LiveBroadcast.score_changed(@game, event: :goal_removed)
    end
  end
end
