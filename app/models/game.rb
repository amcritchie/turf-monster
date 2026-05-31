class Game < ApplicationRecord
  include Sluggable

  belongs_to :home_team, class_name: "Team", foreign_key: :home_team_slug, primary_key: :slug
  belongs_to :away_team, class_name: "Team", foreign_key: :away_team_slug, primary_key: :slug
  belongs_to :advancing_team, class_name: "Team", foreign_key: :advancing_team_slug, primary_key: :slug, optional: true
  belongs_to :survivor_round, optional: true
  has_many :goals, foreign_key: :game_slug, primary_key: :slug, dependent: :destroy

  # Recount goals and update home_score / away_score from Goal records
  def update_scores_from_goals!
    self.home_score = goals.where(team_slug: home_team_slug).count
    self.away_score = goals.where(team_slug: away_team_slug).count
    save!
    update_slate_matchups!
  end

  # Propagate scores to all SlateMatchups referencing this game
  def update_slate_matchups!
    SlateMatchup.where(game_slug: slug).find_each do |matchup|
      team_goals = if matchup.team_slug == home_team_slug
        home_score
      elsif matchup.team_slug == away_team_slug
        away_score
      end
      matchup.update!(goals: team_goals) if team_goals
    end
    score_affected_contests!
  end

  # Find all contests that include this game's matchups and re-score entries
  def score_affected_contests!
    slate_ids = SlateMatchup.where(game_slug: slug).pluck(:slate_id).uniq
    Contest.where(slate_id: slate_ids, status: [:open]).find_each do |contest|
      contest.score_entries!
    end
  end

  def name_slug
    "#{home_team_slug}-vs-#{away_team_slug}"
  end
end
