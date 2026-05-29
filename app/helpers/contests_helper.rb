module ContestsHelper
  # Whether the current viewer is allowed to see this entry's picks.
  # While the contest is `open`, picks are private to the entry owner so
  # network-tab readers can't preview competitors' selections. Once the
  # contest transitions to `locked` (or `settled`) picks are public.
  # Admins on the `/contests/:slug/admin` URL bypass the guard entirely.
  def picks_visible_for?(entry, contest = @contest)
    return true unless contest&.open?
    return true if @admin_view && current_user&.admin?
    return true if logged_in? && entry.user_id == current_user.id
    false
  end

  # Serialize entries for the JSON debug block while respecting the
  # picks-visibility rule above. When picks are hidden for the viewer,
  # the selections array is stripped from the entry's payload — every
  # other field is preserved so the block stays useful for debugging.
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
