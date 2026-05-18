module ApplicationHelper
  CONTEST_BADGE_STYLES = {
    "open"    => "bg-mint-900/30 text-mint border-mint-700",
    "locked"  => "bg-yellow-900/50 text-yellow-400 border-yellow-700",
    "settled" => "bg-surface-alt text-muted border-subtle",
    "pending" => "bg-violet-900/30 text-violet border-violet-700"
  }.freeze

  def contest_badge_classes(status)
    CONTEST_BADGE_STYLES[status] || ""
  end

  def dollars(amount)
    "$#{sprintf('%.2f', amount)}"
  end

  def format_turf_score(value)
    return "—" unless value
    value == value.to_i ? value.to_i.to_s : sprintf('%.1f', value)
  end
end
