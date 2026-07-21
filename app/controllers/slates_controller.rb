class SlatesController < ApplicationController
  before_action :require_admin
  before_action :set_slate, only: [:show, :update_rankings, :update_turf_scores, :update_formula]

  def index
    real_slates = Slate.where.not(name: "Default")
    slate = real_slates.where("starts_at >= ?", Time.current).order(starts_at: :asc).first ||
            real_slates.order(starts_at: :desc, created_at: :desc).first
    return redirect_to root_path, alert: "No slates found" unless slate
    redirect_to slate_path(slate)
  end

  def formula_report
    # The report's sample tables and charts render O/U line + over odds +
    # implied probability per team. The odds columns left SlateMatchup in the
    # schema audit (1fd6c50), so no matchup can produce a complete sample —
    # a line-only row (every NFL matchup) crashed the page the moment
    # "NFL 2026 Week 1" became the next upcoming slate. Until an odds source
    # returns, the page renders as its static formula reference.
    @sample_matchups = []
  end

  # NFL analog of the formula report, on its own tab. nil (empty state) when
  # the historical dataset is missing (ArgumentError), corrupt
  # (JSON::ParserError), or malformed (KeyError from the fetch reads).
  def nfl_report
    @nfl_distribution = begin
      Nfl::PointsDistribution.call
    rescue ArgumentError, JSON::ParserError, KeyError
      nil
    end
  end

  def show
    @slates = Slate.selector_ordered
    @matchups = @slate.slate_matchups.ranked.includes(:team, :opponent_team, :game)
    # The page ranks TEAMS, not matchup rows: a team's standing is its summed
    # expected points across every game it plays in this slate. A one-week slate
    # yields one row per team exactly as before; a "Weeks 1-3" slate yields 32
    # rows rather than 96.
    @team_rows = @slate.team_rows
  end

  def update_rankings
    rescue_and_log(target: @slate) do
      if params[:matchup_ids].present?
        # The dragged rows are TEAMS. Each posted id identifies a team via one of
        # its matchups, and the rank it lands on is written to EVERY game that
        # team plays in this slate — otherwise a multi-week team would be priced
        # by whichever of its three rows happened to be the handle.
        n = params[:matchup_ids].size
        params[:matchup_ids].each_with_index do |id, index|
          matchup = @slate.slate_matchups.find_by(id: id)
          next unless matchup

          rank = index + 1
          @slate.slate_matchups.where(team_slug: matchup.team_slug).find_each do |team_matchup|
            team_matchup.update!(rank: rank, turf_score: SlateMatchup.turf_score_for(rank, n, sport: @slate.sport))
          end
        end
      end
      redirect_to slate_path(@slate), notice: "Rankings saved! Multipliers recalculated."
    end
  rescue StandardError => e
    redirect_to @slate ? slate_path(@slate) : root_path, alert: e.message
  end

  def update_turf_scores
    rescue_and_log(target: @slate) do
      if params[:turf_scores].present?
        params[:turf_scores].each do |entry|
          matchup = @slate.slate_matchups.find_by(id: entry[:id])
          next unless matchup

          # Same as update_rankings: the edited row is a TEAM, so the multiplier
          # applies to every game that team plays here.
          @slate.slate_matchups.where(team_slug: matchup.team_slug)
                .update_all(turf_score: entry[:turf_score].to_f.round(1))
        end
      end
      redirect_to slate_path(@slate), notice: "Turf Scores saved!"
    end
  rescue StandardError => e
    redirect_to @slate ? slate_path(@slate) : root_path, alert: e.message
  end

  def update_formula
    rescue_and_log(target: @slate) do
      @slate.update!(formula_params)
      redirect_to slate_path(@slate), notice: "Formula saved!"
    end
  rescue StandardError => e
    redirect_to @slate ? slate_path(@slate) : root_path, alert: e.message
  end

  def admin_formula
    @default_slate = Slate.default_record
    unless @default_slate
      @default_slate = Slate.create!(name: "Default")
    end
  end

  def update_admin_formula
    @default_slate = Slate.default_record
    return redirect_to root_path, alert: "Default slate not found" unless @default_slate

    rescue_and_log(target: @default_slate) do
      @default_slate.update!(formula_params)
      redirect_to admin_formula_slates_path, notice: "Default formula saved!"
    end
  rescue StandardError => e
    redirect_to admin_formula_slates_path, alert: e.message
  end

  private

  def set_slate
    @slate = Slate.find_by(slug: params[:id])
    return redirect_to root_path, alert: "Slate not found" unless @slate
  end

  def formula_params
    params.permit(*Slate::FORMULA_COLUMNS)
  end
end
