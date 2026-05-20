namespace :survivor do
  desc "Seed the 8 World Cup Survivor rounds and link group-stage games (idempotent)"
  task seed_wc2026: :environment do
    # ET — EDT in June/July 2026 is UTC-4, matching db/seeds.rb game kickoffs.
    et = ->(y, m, d, h = 0, min = 0) { Time.new(y, m, d, h, min, 0, "-04:00") }

    rounds = [
      { number: 1, name: "Group Matchday 1", stage: "group",
        window: [et.(2026, 6, 11), et.(2026, 6, 18)] },
      { number: 2, name: "Group Matchday 2", stage: "group",
        window: [et.(2026, 6, 18), et.(2026, 6, 24)] },
      { number: 3, name: "Group Matchday 3", stage: "group",
        window: [et.(2026, 6, 24), et.(2026, 6, 28)] },
      { number: 4, name: "Round of 32",    stage: "knockout", picks_lock_at: et.(2026, 6, 28, 12) },
      { number: 5, name: "Round of 16",    stage: "knockout", picks_lock_at: et.(2026, 7,  4, 12) },
      { number: 6, name: "Quarter-finals", stage: "knockout", picks_lock_at: et.(2026, 7,  9, 15) },
      { number: 7, name: "Semi-finals",    stage: "knockout", picks_lock_at: et.(2026, 7, 14, 15) },
      { number: 8, name: "Final",          stage: "knockout", picks_lock_at: et.(2026, 7, 19, 15) }
    ]

    puts "Seeding World Cup Survivor rounds..."

    rounds.each do |spec|
      round = SurvivorRound.find_or_initialize_by(number: spec[:number])
      round.name  = spec[:name]
      round.stage = spec[:stage]

      if spec[:window]
        from, to = spec[:window]
        round.save!
        # Group matchdays map cleanly onto distinct date windows of the 72
        # seeded group-stage games. Knockout fixtures are linked later (task 6).
        linked = Game.where(kickoff_at: from...to).update_all(survivor_round_id: round.id)
        round.update!(picks_lock_at: round.games.minimum(:kickoff_at))
        puts "  Round #{spec[:number]}: #{spec[:name]} — #{linked} games linked, " \
             "picks lock #{round.picks_lock_at&.iso8601 || 'TBD (no games seeded — run db:seed)'}"
      else
        round.picks_lock_at = spec[:picks_lock_at]
        round.save!
        puts "  Round #{spec[:number]}: #{spec[:name]} — knockout, " \
             "picks lock #{round.picks_lock_at.iso8601} (fixtures seeded later)"
      end
    end

    puts "Done. #{SurvivorRound.count} rounds, " \
         "#{Game.where.not(survivor_round_id: nil).count} games linked."
  end
end
