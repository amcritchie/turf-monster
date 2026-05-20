module Admin
  class LandingPagesController < ApplicationController
    before_action :require_admin
    before_action :set_landing_page, only: %i[edit update destroy]
    before_action :load_contests,    only: %i[new create edit update]

    def index
      @landing_pages = LandingPage.includes(:contest).order(created_at: :desc)
    end

    def new
      @landing_page = LandingPage.new
    end

    def create
      @landing_page = LandingPage.new(landing_page_params)
      return render :new, status: :unprocessable_entity if @landing_page.invalid?

      rescue_and_log(target: @landing_page) do
        @landing_page.save!
        redirect_to admin_landing_pages_path, notice: %(Landing page "#{@landing_page.name}" created.)
      end
    end

    def edit; end

    def update
      @landing_page.assign_attributes(landing_page_params)
      return render :edit, status: :unprocessable_entity if @landing_page.invalid?

      rescue_and_log(target: @landing_page) do
        @landing_page.save!
        redirect_to admin_landing_pages_path, notice: %(Landing page "#{@landing_page.name}" updated.)
      end
    end

    def destroy
      rescue_and_log(target: @landing_page) do
        @landing_page.destroy!
        redirect_to admin_landing_pages_path, notice: "Landing page deleted."
      end
    end

    private

    def set_landing_page
      @landing_page = LandingPage.find_by(slug: params[:slug])
      redirect_to admin_landing_pages_path, alert: "Landing page not found." unless @landing_page
    end

    def load_contests
      # All contests, both game types — a landing page can funnel to a
      # Turf Totals or a World Cup Survivor contest.
      @contests = Contest.order(created_at: :desc)
    end

    def landing_page_params
      params.require(:landing_page).permit(:name, :slug, :headline, :subheadline, :cta_label, :contest_id, :active)
    end
  end
end
