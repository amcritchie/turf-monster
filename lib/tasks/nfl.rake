namespace :nfl do
  desc "Cache expected NFL team totals from the baseline sportsbook CSV"
  task expected_team_totals_cache: :environment do
    year = ENV.fetch("YEAR", Nfl::CacheExpectedTeamTotals::DEFAULT_YEAR)
    path = ENV["CSV_PATH"].presence || Nfl::CacheExpectedTeamTotals::DEFAULT_PATH
    load Rails.root.join("db/seeds/nfl_2026.rb") unless ENV["SKIP_SCHEDULE"] == "1"
    result = Nfl::CacheExpectedTeamTotals.call(year: year, path: path)
    puts "Cached NFL #{result.year} expected team totals: " \
         "#{result.rows} games, #{result.projections_upserted} team rows, " \
         "#{result.games_created} games created, #{result.slates_created} slates created, " \
         "#{result.matchups_created} matchups created, #{result.stale_deleted} stale deleted."
  end
end
