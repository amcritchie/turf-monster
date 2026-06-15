class TeamsController < ApplicationController
  skip_before_action :require_authentication

  def index
    @teams = Team.includes(:players, :home_arena).order(:name)
  end

  def show
    @team = Team.includes(:home_arena, :players, home_games: [:home_team, :away_team], away_games: [:home_team, :away_team]).find_by(slug: params[:id])
    return redirect_to teams_path, alert: "Team not found" unless @team
  end
end
