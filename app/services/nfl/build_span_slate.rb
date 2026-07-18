module Nfl
  # Builds (or refreshes) the single Slate that a multi-week contest is played
  # on — e.g. "NFL 2026 Weeks 1-3", holding every game those weeks contain.
  #
  # This is the convergence point for multi-week scoring. A Slate is a POOL OF
  # GAMES, so one span slate holds three games per team, and ranking it stores a
  # FROZEN per-team turf_score on every one of those rows. Scoring then reads the
  # stored value instead of recomputing across a set of weekly slates, which is
  # what let a pick be priced at 1.0x and settled at 3.0x.
  #
  # Refuses rather than truncates:
  #   * a gap in the requested weeks (a "Weeks 1-3" that silently skipped week 2
  #     would be sold as three weeks and scored as two)
  #   * a year with no weekly slates at all
  # Scoping every lookup by YEAR is what keeps a 2026 span from absorbing a 2025
  # slate — slates carry a week but no year column, so the year lives in the name.
  class BuildSpanSlate
    class Error < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(year:, weeks:)
      @year = year.to_i
      @weeks = Array(weeks).map(&:to_i).uniq.sort
    end

    def call
      raise Error, "Need at least one week" if @weeks.empty?

      sources = source_slates
      slate = ensure_slate!
      rebuild_matchups!(slate, sources)
      freeze_rankings!(slate)
      slate.reload
    end

    def self.slate_name(year, weeks)
      weeks.size == 1 ? "NFL #{year} Week #{weeks.first}" : "NFL #{year} Weeks #{weeks.first}-#{weeks.last}"
    end

    private

    # The weekly slates the span is assembled from, scoped to THIS year by name.
    # Every requested week must exist — a missing one is an error, not a shorter
    # contest.
    def source_slates
      # Sources must be SINGLE-week slates. A span slate is itself named
      # "NFL 2026 Weeks 1-3" and carries week=1, so without this filter a REBUILD
      # matched the span as its own source for week 1, wiped its rows, and then
      # copied from the now-empty slate — silently returning a shorter span.
      candidates = Slate.where(week: @weeks)
                        .where("name LIKE ?", "NFL #{@year} %")
                        .reject { |slate| slate.week_range.nil? || slate.week_range.size > 1 }

      scoped = candidates.index_by(&:week)
      missing = @weeks - scoped.keys

      if missing.any?
        raise Error, "NFL #{@year} has no slate for week#{'s' if missing.size > 1} #{missing.join(', ')}"
      end

      @weeks.map { |week| scoped.fetch(week) }
    end

    def ensure_slate!
      name = self.class.slate_name(@year, @weeks)
      Slate.find_or_create_by!(name: name) do |slate|
        slate.slug = name.parameterize
        slate.week = @weeks.first
      end
    end

    # Rebuilt wholesale rather than merged, so a re-run after a projections
    # refresh can't leave a stale game behind.
    def rebuild_matchups!(slate, sources)
      slate.slate_matchups.destroy_all

      sources.each do |source|
        source.slate_matchups.each do |matchup|
          slate.slate_matchups.create!(
            week: matchup.week || source.week,
            team_slug: matchup.team_slug,
            opponent_team_slug: matchup.opponent_team_slug,
            game_slug: matchup.game_slug,
            dk_goals_expectation: matchup.dk_goals_expectation,
            status: matchup.status
          )
        end
      end
    end

    # Store the span ranking on EVERY row of each team. This is the freeze: the
    # multiplier a player is shown at pick time is the one settlement multiplies
    # by, because both read this column.
    def freeze_rankings!(slate)
      rankings = slate.team_rankings

      slate.slate_matchups.find_each do |matchup|
        ranking = rankings[matchup.team_slug]
        next if ranking.nil?

        matchup.update!(rank: ranking[:rank], turf_score: ranking[:turf_score])
      end
    end
  end
end
