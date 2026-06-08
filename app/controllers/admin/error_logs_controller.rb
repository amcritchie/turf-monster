module Admin
  # Read-only incident-triage browser over ErrorLog (engine model, host
  # namespace). First-stop tool for diagnosing prod failures captured by
  # rescue_and_log / ErrorLog.capture! — see the backend-development discipline.
  #
  # Richer than the engine's /error_logs: exception-class facets, a target_type
  # filter, summary stats, and deep-links to target/parent records. There is no
  # exception-class column, so the class is parsed from the `inspect` column
  # (Admin::ErrorLogsHelper.error_class_from_inspect).
  #
  # Both actions are wrapped so any failure is captured to ErrorLog and rendered
  # gracefully — the viewer itself never 500s (operator directive).
  class ErrorLogsController < ApplicationController
    before_action :require_admin

    LIMIT = 200

    def index
      rescue_and_log do
        scope = ErrorLog.order(created_at: :desc)

        if params[:q].present?
          like  = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%"
          scope = scope.where("message ILIKE ?", like)
        end

        scope = scope.where(target_type: params[:target_type]) if params[:target_type].present?

        if params[:klass].present?
          # Anchor at the class position in "#<ClassName: msg>" so we match the
          # exception class, not the same word appearing inside a message.
          klass_like = "#<#{ActiveRecord::Base.sanitize_sql_like(params[:klass])}%"
          scope = scope.where("inspect ILIKE ?", klass_like)
        end

        if params[:since].present? && (since = parse_since(params[:since]))
          scope = scope.where("created_at >= ?", since)
        end

        @error_logs = scope.limit(LIMIT)
        @summary    = build_summary
      end
    rescue StandardError => e
      # rescue_and_log already captured it; render an empty, friendly page
      # instead of bubbling to a 500 / generic error redirect.
      @error_logs = ErrorLog.none
      @summary    = blank_summary
      flash.now[:alert] = "Could not load error logs: #{e.message}"
      render :index
    end

    def show
      rescue_and_log do
        @error_log   = ErrorLog.find_by!(slug: params[:slug])
        @error_class = helpers.error_class_for(@error_log)
        @backtrace   = decode_backtrace(@error_log.backtrace)
      end
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_error_logs_path, alert: "Error log not found."
    rescue StandardError => e
      redirect_to admin_error_logs_path, alert: "Could not load error log: #{e.message}"
    end

    private

    def build_summary
      recent = ErrorLog.where("created_at >= ?", 24.hours.ago)

      {
        total:           ErrorLog.count,
        last_24h:        recent.count,
        top_classes_24h: top_classes(recent),
        by_target_type:  ErrorLog.where.not(target_type: nil).group(:target_type).count
      }
    end

    def blank_summary
      { total: 0, last_24h: 0, top_classes_24h: [], by_target_type: {} }
    end

    # Tally exception classes in the given scope by parsing the `inspect` column.
    # No class column exists, so this is a Ruby-side tally of the pluck'd strings.
    # Returns [[class_name, count], ...] newest-heaviest first, top 8.
    def top_classes(scope)
      scope.pluck(:inspect)
           .map { |i| Admin::ErrorLogsHelper.error_class_from_inspect(i) }
           .tally
           .sort_by { |_klass, count| -count }
           .first(8)
    end

    # backtrace is stored as a JSON array string; guard malformed/blank values.
    def decode_backtrace(raw)
      return [] if raw.blank?

      parsed = JSON.parse(raw)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    def parse_since(value)
      Time.zone.parse(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
