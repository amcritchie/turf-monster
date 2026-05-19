module Admin
  class SeasonsController < ApplicationController
    before_action :require_admin

    def index
      @seasons = (vault.list_seasons rescue [])
      @current_season_id = SeasonConfig.current_season_id
      @next_season_id = (@seasons.map { |s| s[:season_id] }.max || 0) + 1
    end

    def create
      rescue_and_log do
        name = params[:name].to_s.strip
        season_id = params[:season_id].to_i
        schedule = (0..4).map { |i| params[:"slot_#{i}"].to_i }
        raise "Name required" if name.blank?
        raise "Schedule must be 5 non-negative integers" unless schedule.length == 5 && schedule.all? { |v| v >= 0 }

        result = vault.create_season(season_id: season_id, name: name, schedule: schedule)
        SeasonConfig.set_current!(season_id) if params[:set_current] == "1"
        flash[:notice] = "Created season \"#{name}\" (id=#{season_id}). TX: #{result[:signature][0, 16]}…"
      end
      redirect_to admin_seasons_path
    end

    def set_current
      season_id = params[:season_id].to_i
      SeasonConfig.set_current!(season_id)
      flash[:notice] = "Set current season to id=#{season_id}"
      redirect_to admin_seasons_path
    end

    private

    def vault
      @vault ||= Solana::Vault.new
    end
  end
end
