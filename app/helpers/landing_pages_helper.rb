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
      required_picks = contest&.picks_required || Contest::TURF_TOTALS_DEFAULT_PICKS_REQUIRED
      [
        ["Pick #{required_picks} teams", "Choose #{required_picks} World Cup team matchups for your entry."],
        ["Create Account", "Sign up with email or Google — it only takes a few seconds."],
        ["Submit Entry", "Confirm your #{required_picks} picks and submit your entry."],
        ["Contest Locks", "The contest locks and games are simulated Wednesday the 27th at 8 PM MST."]
      ]
    end
  end
end
