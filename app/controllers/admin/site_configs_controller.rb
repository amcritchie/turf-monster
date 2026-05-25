module Admin
  class SiteConfigsController < ApplicationController
    before_action :require_admin

    def show
      @season_config = SeasonConfig.current
      @explicit_main = SeasonConfig.main_contest_explicit
      @resolved_main = SeasonConfig.main_contest
      # Open + locked are reasonable "main" candidates. Settled contests are
      # excluded — pointing the share/root surfaces at a finished contest
      # would route new traffic to a dead end.
      @selectable_contests = Contest.where(status: [:open, :locked])
                                    .order(created_at: :desc)
    end

    def update
      rescue_and_log(target: SeasonConfig.current) do
        # Blank string from the dropdown's "— none —" option clears the
        # pointer; otherwise we coerce to an integer ID before save.
        raw = params[:main_contest_id].to_s
        id  = raw.empty? ? nil : raw.to_i
        SeasonConfig.set_main_contest!(id)
        redirect_to admin_site_config_path, notice: "Main contest updated."
      end
    rescue StandardError => e
      redirect_to admin_site_config_path, alert: "Failed to update: #{e.message}"
    end
  end
end
