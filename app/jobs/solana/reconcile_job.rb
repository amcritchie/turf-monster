module Solana
  # Sidekiq cron job that runs Solana::Reconciler#reconcile_all on a schedule
  # and fans discrepancies out to RECONCILER_ALERT_WEBHOOK (if set), falling
  # back to the existing ErrorLog write inside Reconciler.
  #
  # Scheduled via config/schedule.yml (loaded by config/initializers/sidekiq_cron.rb).
  # Default cadence: every 15 minutes.
  #
  # Run manually for testing: Solana::ReconcileJob.perform_now
  class ReconcileJob < ApplicationJob
    queue_as :default

    def perform
      result = Solana::Reconciler.new.tap(&:reconcile_all)
      return if result.discrepancies.empty?

      notify_webhook(result.discrepancies)
    end

    private

    def notify_webhook(discrepancies)
      url = ENV["RECONCILER_ALERT_WEBHOOK"]
      return if url.blank?

      payload = {
        text: ":rotating_light: Solana reconciler found #{discrepancies.size} discrepancy(ies)",
        attachments: [{
          color: "danger",
          fields: discrepancies.first(10).map { |d|
            { title: d[:type].to_s, value: d.except(:type).to_json[0, 500], short: false }
          }
        }]
      }

      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
        req.body = payload.to_json
        http.request(req)
      end
    rescue => e
      Rails.logger.error "[ReconcileJob] webhook delivery failed: #{e.class}: #{e.message}"
      # Swallow — the ErrorLog write inside Reconciler already preserves discrepancy detail.
    end
  end
end
