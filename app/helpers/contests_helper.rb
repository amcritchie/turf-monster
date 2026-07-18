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
  # "W1 2.0 · W2 6.0 · W3 3.0 = 11.0 pts". An unplayed week (or a bye, which has
  # no matchup at all) shows a dash rather than a zero, so "hasn't happened yet"
  # reads differently from "was shut out".
  #
  # `weeks` and `by_team` are hoisted by the caller (contest.week_slates /
  # contest.matchups_by_team) so rendering a full leaderboard stays two queries
  # rather than two per pick.
  def weekly_points_breakdown(selection, weeks:, by_team:)
    pool = by_team[selection.slate_matchup.team_slug] || []
    parts = weeks.map do |slate|
      matchup = pool.find { |m| m.slate_id == slate.id }
      value = if matchup&.goals.present? && matchup&.turf_score.present?
        format("%.1f", matchup.goals * matchup.turf_score)
      else
        "—"
      end
      "W#{slate.week || '?'} #{value}"
    end

    "#{parts.join(' · ')} = #{format('%.1f', selection.points.to_f)} pts"
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
