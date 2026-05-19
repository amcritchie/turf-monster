# Trims the outbound_requests audit table on a schedule (config/schedule.yml).
#
# Retention policy:
#   - successful rows  → 90 days
#   - failed     rows  → 180 days (keep longer for incident review)
#
# Uses delete_all (no callbacks, no instantiation) since rows are immutable.
class OutboundRequestSweeperJob < ApplicationJob
  queue_as :default

  SUCCESS_RETENTION = 90.days
  FAILURE_RETENTION = 180.days

  def perform
    deleted_ok   = OutboundRequest.successful.where("created_at < ?", SUCCESS_RETENTION.ago).delete_all
    deleted_fail = OutboundRequest.failed.where("created_at < ?",     FAILURE_RETENTION.ago).delete_all

    Rails.logger.info "[outbound_request_sweeper] deleted=#{deleted_ok + deleted_fail} (ok=#{deleted_ok}, fail=#{deleted_fail})"
  end
end
