module ContestsHelper
  # Whether the current viewer is allowed to see this entry's picks.
  # While the contest is open and not yet locked, picks are private to the
  # entry owner so network-tab readers can't preview competitors' selections.
  # Once the contest locks (v0.17: DERIVED — its lock time has passed) or
  # settles, picks are public. Admins on the `/contests/:slug/admin` URL
  # bypass the guard entirely.
  def picks_visible_for?(entry, contest = @contest)
    return true unless contest&.open?   # nil or settled → public
    return true if contest.locked?      # derived: lock time passed → public
    return true if @admin_view && current_user&.admin?
    return true if logged_in? && entry.user_id == current_user.id
    false
  end

  # Serialize entries for the JSON debug block while respecting the
  # picks-visibility rule above. When picks are hidden for the viewer,
  # the selections array is stripped from the entry's payload — every
  # other field is preserved so the block stays useful for debugging.
  # Per-week breakdown for one pick in a multi-week contest, e.g.
  # "W1 2 · W2 3 · W3 — · 5 goals × 2.4 = 12.0 pts".
  #
  # Shows GOALS per week, then the single span multiplier — mirroring how the
  # score is actually computed (total goals × one multiplier), so the tooltip
  # can't imply a per-week multiplier that doesn't exist. An unplayed week (or a
  # bye, which has no matchup at all) shows a dash rather than a zero, so
  # "hasn't happened yet" reads differently from "was shut out".
  #
  # `weeks`, `by_team`, and `multiplier` are hoisted by the caller so rendering a
  # full leaderboard stays a couple of queries rather than a couple per pick.
  def weekly_points_breakdown(selection, weeks:, by_team:, multiplier: nil)
    pool = by_team[selection.slate_matchup.team_slug] || []
    total = 0
    parts = weeks.map do |week|
      matchup = pool.find { |m| m.week == week }
      if matchup&.goals.present?
        total += matchup.goals
        "W#{week || '?'} #{matchup.goals}"
      else
        "W#{week || '?'} —"
      end
    end

    tail = "#{total} goals"
    tail += " × #{multiplier}" if multiplier.present?
    "#{parts.join(' · ')} · #{tail} = #{format('%.1f', selection.points.to_f)} pts"
  end

  def contest_debug_entries(entries, contest = @contest)
    entries.map do |entry|
      if picks_visible_for?(entry, contest)
        entry.as_json(include: { user: { only: [:id, :name] }, selections: {} })
      else
        entry.as_json(include: { user: { only: [:id, :name] } })
      end
    end
  end
end
