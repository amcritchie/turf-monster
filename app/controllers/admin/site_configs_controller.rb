module Admin
  class SiteConfigsController < ApplicationController
    before_action :require_admin

    def show
      @season_config = SeasonConfig.current
      @site_setting  = SiteSetting.instance
      @explicit_main = SeasonConfig.main_contest_explicit
      @resolved_main = SeasonConfig.main_contest
      # Open contests are the "main" candidates (locking is derived now, not a
      # status — an open-but-time-locked contest is still a valid pick).
      # Settled contests are excluded — pointing the share/root surfaces at a
      # finished contest would route new traffic to a dead end.
      @selectable_contests = Contest.where(status: [:open])
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

    # Default og:image title + description (SiteSetting singleton).
    def update_link_preview
      rescue_and_log(target: SiteSetting.instance) do
        SiteSetting.instance.update!(link_preview_params)
        redirect_to admin_site_config_path, notice: "Link-preview defaults updated."
      end
    rescue StandardError => e
      redirect_to admin_site_config_path, alert: "Failed to update: #{e.message}"
    end

    # Immediate cropper save for the default og:image (mirrors the contest
    # banner flow — its own multipart form, refreshes the preview via Turbo).
    def update_link_preview_image
      rescue_and_log(target: SiteSetting.instance) do
        file = params.dig(:site_setting, :default_og_image)

        if valid_image?(file)
          SiteSetting.instance.default_og_image.attach(file)
          respond_to do |format|
            format.turbo_stream do
              render turbo_stream: turbo_stream.replace(
                "default-og-image-preview",
                partial: "admin/site_configs/og_image_preview",
                locals: { site_setting: SiteSetting.instance }
              )
            end
            format.html { redirect_to admin_site_config_path, notice: "Default link-preview image updated." }
          end
        else
          message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, or WebP under 8 MB."
          redirect_to admin_site_config_path, alert: message, status: :see_other
        end
      end
    end

    private

    def link_preview_params
      params.require(:site_setting).permit(:default_og_title, :default_og_description)
    end
  end
end
