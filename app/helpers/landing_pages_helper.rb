module LandingPagesHelper
  # Funnel "how it works" steps, tailored to the wired contest's game type.
  # Falls back to Turf Totals when no contest is wired yet (draft preview).
  def funnel_how_it_works(contest)
    if contest&.world_cup_survivor?
      [
        ["Enter the contest", "One entry per player — claim your spot before the tournament locks."],
        ["Pick a team each round", "Back a different team every round. No team can be used twice."],
        ["Win or draw to survive", "A loss eliminates you. The last player standing takes the prize."]
      ]
    else
      [
        ["Pick 6 teams", "Choose six World Cup team matchups for your entry."],
        ["Goals × Turf Score", "Each team scores its goals times a Turf Score multiplier."],
        ["Top scores win cash", "The highest entry totals split the prize pool."]
      ]
    end
  end
end
