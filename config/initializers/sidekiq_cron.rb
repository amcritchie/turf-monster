# Load sidekiq-cron schedule from config/schedule.yml on Sidekiq server boot.
# Web processes don't load this (no cron registration needed there); the
# Sidekiq::Cron::Job.load_from_hash! call below is guarded on Sidekiq.server?.
#
# To bypass the schedule (e.g. during a one-off backfill that you don't want
# the cron to step on), set SIDEKIQ_CRON_DISABLED=1.

require "sidekiq"

if defined?(Sidekiq) && Sidekiq.server? && ENV["SIDEKIQ_CRON_DISABLED"].blank?
  Sidekiq.configure_server do |_config|
    schedule_path = Rails.root.join("config", "schedule.yml")
    if schedule_path.exist?
      require "sidekiq-cron"
      schedule = YAML.load_file(schedule_path)
      Sidekiq::Cron::Job.load_from_hash!(schedule)
      Rails.logger.info "[sidekiq-cron] loaded #{schedule.size} scheduled job(s) from #{schedule_path}"
    end
  end
end
