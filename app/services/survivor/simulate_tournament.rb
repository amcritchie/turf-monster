module Survivor
  # Dry-runs a full 8-round World Cup Survivor tournament inside a transaction
  # that always rolls back — real games, rounds, contests and entries are left
  # exactly as they were. Returns a report of how the field thinned and who
  # would win. Knockout fixtures are generated on the fly, since the real
  # bracket only exists once the group stage ends.
  class SimulateTournament
    def self.call(contest, fill_to: 30)
      new(contest, fill_to: fill_to).call
    end

    def initialize(contest, fill_to: 30)
      @contest    = contest
      @fill_to    = fill_to
      @rounds_log = []
    end

    def call
      raise "Not a survivor contest" unless @contest.world_cup_survivor?

      report = nil
      ActiveRecord::Base.transaction do
        fill_entries
        SurvivorRound.ordered.each { |round| run_round(round) }
        report = build_report
        raise ActiveRecord::Rollback
      end
      report
    end

    private

    def run_round(round)
      ensure_games(round)
      make_picks(round)
      simulate_results(round)

      before = contest_entries.count(&:alive?)
      Survivor::GradeRound.call(round)
      after = contest_entries.count(&:alive?)

      @rounds_log << {
        number: round.number, name: round.name, stage: round.stage,
        alive_before: before, alive_after: after, eliminated: before - after
      }
    end

    # Group rounds already have their 24 seeded games. Knockout rounds get
    # fixtures generated from the previous round's advancers (round 4 seeds
    # from a random 32).
    def ensure_games(round)
      return if round.games.exists?

      @knockout_teams ||= Team.order(Arel.sql("RANDOM()")).limit(32).to_a
      pair_into_games(@knockout_teams, round)
    end

    def pair_into_games(teams, round)
      teams.shuffle.each_slice(2) do |home, away|
        next unless home && away
        # Avoid colliding with an existing game's "home-vs-away" slug.
        home, away = away, home if Game.exists?(slug: "#{home.slug}-vs-#{away.slug}")
        Game.create!(
          home_team_slug: home.slug, away_team_slug: away.slug,
          survivor_round: round, status: "scheduled",
          kickoff_at: round.picks_lock_at || Time.current
        )
      end
    end

    def make_picks(round)
      playing = round.games.flat_map { |g| [g.home_team_slug, g.away_team_slug] }.uniq
      contest_entries.each do |entry|
        next unless entry.alive?
        next if entry.survivor_picks.any? { |p| p.survivor_round_id == round.id }

        choice = (playing - entry.survivor_picks.map(&:team_slug)).sample
        entry.survivor_picks.create!(survivor_round: round, team_slug: choice) if choice
      end
    end

    def simulate_results(round)
      if round.group_stage?
        round.games.each do |g|
          g.update!(home_score: rand(0..4), away_score: rand(0..4), status: "completed")
        end
      else
        advancers = []
        round.games.each do |g|
          winner = [g.home_team_slug, g.away_team_slug].sample
          g.update!(home_score: rand(0..3), away_score: rand(0..3),
                    status: "completed", advancing_team_slug: winner)
          advancers << winner
        end
        @knockout_teams = Team.where(slug: advancers).to_a
      end
    end

    def fill_entries
      return if @fill_to.to_i <= 0

      need = @fill_to - @contest.entries.where(status: %w[active complete]).count
      return if need <= 0

      users = User.limit(12).to_a
      raise "No users available to fill simulated entries" if users.empty?
      need.times { |i| @contest.entries.create!(user: users[i % users.size], status: "active") }
    end

    def contest_entries
      @contest.entries.where(status: %w[active complete]).includes(:survivor_picks, :user).to_a
    end

    def build_report
      entries = contest_entries
      deepest = entries.map(&:rounds_survived).max || 0
      winners = entries.select { |e| e.rounds_survived == deepest }
      prize   = @contest.guaranteed_prize_cents

      {
        contest:          @contest.name,
        total_entries:    entries.size,
        rounds:           @rounds_log,
        max_rounds:       deepest,
        winners:          winners.map { |e| e.user.display_name },
        prize_cents:      prize,
        prize_each_cents: winners.any? ? prize / winners.size : 0
      }
    end
  end
end
