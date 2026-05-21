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

  desc "Create the two World Cup Survivor contests (paid + free) — fires on-chain creation"
  task create_contests: :environment do
    admin = User.find_by(email: "alex@mcritchie.studio")
    raise "Admin user alex@mcritchie.studio not found — run db:seed first" unless admin

    specs = [
      { name: "World Cup Survivor",          contest_type: "survivor_wc_paid" },
      { name: "World Cup Survivor Free Roll", contest_type: "survivor_wc_free" }
    ]

    specs.each do |spec|
      slug = spec[:name].parameterize
      if (existing = Contest.find_by(slug: slug))
        puts "  • #{spec[:name]} — already exists (on-chain: #{existing.onchain? ? existing.onchain_contest_id : 'NO'})"
        next
      end

      format = Contest::FORMATS.fetch(spec[:contest_type])
      begin
        contest = Contest.create!(
          name:            spec[:name],
          game_type:       "world_cup_survivor",
          contest_type:    spec[:contest_type],
          entry_fee_cents: format[:entry_fee_cents],
          max_entries:     format[:max_entries],
          status:          "open",
          user:            admin
        )
        puts "  ✓ #{spec[:name]} — slug=#{contest.slug}  " \
             "entry=$#{contest.entry_fee_dollars}  prize=$#{contest.guaranteed_prize_dollars}  " \
             "PDA=#{contest.onchain_contest_id}"
      rescue => e
        puts "  ✗ #{spec[:name]} — #{e.message}"
      end
    end
  end

  desc "Dry-run a full 8-round World Cup Survivor tournament (rolls back — nothing persists)"
  task :simulate, [:slug] => :environment do |_t, args|
    slug = args[:slug].presence || "world-cup-survivor-free-roll"
    contest = Contest.find_by(slug: slug)
    raise "Contest not found: #{slug}" unless contest

    puts "Simulating #{contest.name} (#{slug}) — dry run, nothing persists"
    puts
    report = Survivor::SimulateTournament.call(contest)
    total  = [report[:total_entries], 1].max

    puts "  #{report[:total_entries]} entries"
    report[:rounds].each do |r|
      bar = "#" * (r[:alive_after] * 40 / total)
      puts "  R#{r[:number]} #{r[:name].ljust(18)} #{r[:alive_before].to_s.rjust(3)} -> " \
           "#{r[:alive_after].to_s.rjust(3)} alive  (#{r[:eliminated]} out)  #{bar}"
    end
    puts
    if report[:winners].any?
      label = report[:winners].size > 1 ? "Winners" : "Winner"
      puts "  #{label}: #{report[:winners].join(', ')}"
      puts "  Survived #{report[:max_rounds]} round(s) — split $#{report[:prize_cents] / 100} " \
           "= $#{format('%.2f', report[:prize_each_cents] / 100.0)} each"
    else
      puts "  No entries to settle."
    end
    puts
    puts "(rolled back — games, rounds, contests, entries unchanged)"
  end
end
