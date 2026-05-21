module Survivor
  # Grades one World Cup Survivor round across every survivor entry: marks each
  # pick survived/eliminated, eliminates entries that lost or missed their pick,
  # and refreshes each entry's score (= rounds survived).
  #
  # Rounds are global (shared by the paid + free contests), so one call grades
  # every survivor contest at once. Run it only once a round's games are final.
  class GradeRound
    def self.call(round)
      new(round).call
    end

    def initialize(round)
      @round = round
    end

    def call
      games = @round.games.to_a
      raise "#{@round.name} has no games to grade." if games.empty?

      ungraded = games.reject do |g|
        g.status == "completed" && (@round.group_stage? || g.advancing_team_slug.present?)
      end
      if ungraded.any?
        need = @round.knockout? ? "a final result + advancing team" : "a final score"
        raise "#{@round.name}: #{ungraded.size} game(s) still need #{need}."
      end

      # team_slug => the game it played in this round
      game_for = {}
      games.each do |g|
        game_for[g.home_team_slug] = g
        game_for[g.away_team_slug] = g
      end

      ActiveRecord::Base.transaction do
        survivor_entries.each do |entry|
          next if entry.eliminated? # already out in an earlier round

          pick = entry.survivor_picks.find { |p| p.survivor_round_id == @round.id }
          if pick.nil?
            entry.update!(eliminated_round: @round.number) # missed pick = out
          else
            survived = survived?(game_for[pick.team_slug], pick.team_slug)
            pick.update!(result: survived ? "survived" : "eliminated")
            entry.update!(eliminated_round: @round.number) unless survived
          end

          # Denormalized score so the leaderboard + Contest#grade! rank correctly.
          entry.update_column(:score, entry.rounds_survived)
        end

        @round.update!(status: "completed")
      end
    end

    private

    def survivor_entries
      @survivor_entries ||= Entry
        .joins(:contest)
        .where(contests: { game_type: "world_cup_survivor" }, status: %w[active complete])
        .includes(:survivor_picks)
        .to_a
    end

    # A pick survives the round if its team won or drew (group stage) or
    # advanced (knockout). No game found for the team → not survived.
    def survived?(game, team_slug)
      return false unless game

      if @round.group_stage?
        outcome(game, team_slug) != :loss
      else
        game.advancing_team_slug == team_slug
      end
    end

    def outcome(game, team_slug)
      case team_slug
      when game.home_team_slug then compare(game.home_score, game.away_score)
      when game.away_team_slug then compare(game.away_score, game.home_score)
      else :loss # team not in this game — shouldn't happen; treat as out
      end
    end

    def compare(scored, conceded)
      scored = scored.to_i
      conceded = conceded.to_i
      return :win  if scored > conceded
      return :loss if scored < conceded

      :draw
    end
  end
end
