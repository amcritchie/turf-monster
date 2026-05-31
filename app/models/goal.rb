class Goal < ApplicationRecord
  include Sluggable

  belongs_to :game, foreign_key: :game_slug, primary_key: :slug
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug
  belongs_to :player, foreign_key: :player_slug, primary_key: :slug, optional: true

  after_create :update_slug_with_id
  after_create :refresh_game_scores
  after_destroy :refresh_game_scores

  # Live page (Turbo Streams over ActionCable). _commit so scores recomputed by
  # refresh_game_scores (above, runs first) are committed before we broadcast.
  after_create_commit  -> { Contest::LiveBroadcast.goal_scored(self) }
  after_destroy_commit -> { Contest::LiveBroadcast.score_changed(game, event: :goal_removed) }

  def name_slug
    "goal-#{id}"
  end

  def to_param
    slug
  end

  private

  def update_slug_with_id
    update_column(:slug, name_slug)
  end

  def refresh_game_scores
    game.update_scores_from_goals!
  end
end
