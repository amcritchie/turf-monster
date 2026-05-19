module Admin
  class OutboundRequestsController < ApplicationController
    before_action :require_admin

    def index
      scope = OutboundRequest.includes(:user).recent

      scope = scope.for_service(params[:service]) if params[:service].present?
      scope = scope.failed     if params[:failed_only] == "1"
      scope = scope.where("created_at >= ?", Time.zone.parse(params[:since]))   if params[:since].present?
      scope = scope.where("source_type = ? AND source_id = ?", params[:source_type], params[:source_id]) if params[:source_type].present? && params[:source_id].present?

      @outbound_requests = scope.limit(200)

      @summary = {
        total:       OutboundRequest.count,
        last_24h:    OutboundRequest.where("created_at >= ?", 24.hours.ago).count,
        failed_24h:  OutboundRequest.failed.where("created_at >= ?", 24.hours.ago).count,
        by_service:  OutboundRequest.where("created_at >= ?", 24.hours.ago).group(:service).count
      }
    end

    def show
      @outbound_request = OutboundRequest.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_outbound_requests_path, alert: "Outbound request not found"
    end
  end
end
