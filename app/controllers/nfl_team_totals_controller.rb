class NflTeamTotalsController < ApplicationController
  skip_before_action :require_authentication

  SOURCE_URLS = {
    "yahoo_sports_2026_lookahead" => "https://sports.yahoo.com/nfl/betting/article/2026-nfl-betting-lines-odds-for-every-game-this-season-164646933.html"
  }.freeze

  def index
    @year = params.fetch(:year, Nfl::CacheExpectedTeamTotals::DEFAULT_YEAR).to_i
    @available_weeks = NflTeamTotalProjection.for_year(@year).distinct.order(:week).pluck(:week)
    @week = selected_week
    @projections = NflTeamTotalProjection
      .for_year(@year)
      .for_week(@week)
      .includes(:team, :opponent_team, :favorite_team, :game)
      .ordered
    @games = @projections.group_by(&:game_slug)
    @source = @projections.first
    @source_url = SOURCE_URLS[@source&.source]
    @highest_projection = @projections.max_by(&:expected_points)
    @average_expected_points = average_expected_points
  end

  private

  def selected_week
    requested = params[:week].to_i if params[:week].present?
    return requested if requested && @available_weeks.include?(requested)

    @available_weeks.first || 1
  end

  def average_expected_points
    return 0 if @projections.empty?

    @projections.sum { |projection| projection.expected_points.to_d } / @projections.size
  end
end
