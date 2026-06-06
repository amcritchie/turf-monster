module Admin
  # Operator goal-entry console (/admin/scoring). Lists every fixture that
  # belongs to a slate (i.e. is pickable in a contest), soonest kickoff first,
  # so on game day the operator can record goals (team + minute) against the
  # live game. The row forms POST to Admin::GamesController#record_goal /
  # remove_goal / complete_game — this controller only renders the board.
  class ScoringController < ApplicationController
    before_action :require_admin

    def index
      game_slugs = SlateMatchup.where.not(game_slug: nil).distinct.pluck(:game_slug)
      @games = Game.where(slug: game_slugs)
                   .includes(:home_team, :away_team, :goals)
                   .order(Arel.sql("kickoff_at ASC NULLS LAST"))
    end
  end
end
