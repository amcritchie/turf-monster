# frozen_string_literal: true

result = Nfl::CacheExpectedTeamTotals.call(year: 2026)
puts "  Cached NFL #{result.year} expected team totals " \
     "(#{result.rows} games, #{result.projections_upserted} team rows, " \
     "#{result.games_created} games created, #{result.slates_created} slates created)"
