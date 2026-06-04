module ApplicationHelper
  CONTEST_BADGE_STYLES = {
    "open"      => "bg-mint-900/30 text-mint border-mint-700",
    "locked"    => "bg-yellow-900/50 text-yellow-400 border-yellow-700",
    "settled"   => "bg-surface-alt text-muted border-subtle",
    "pending"   => "bg-violet-900/30 text-violet border-violet-700",
    "cancelled" => "bg-red-900/30 text-red-400 border-red-700"
  }.freeze

  def contest_badge_classes(status)
    CONTEST_BADGE_STYLES[status] || ""
  end

  def dollars(amount)
    "$#{sprintf('%.2f', amount)}"
  end

  # The brand mark. Uses the lightweight 45KB icon (not the 1.3MB /logo.png) and
  # always sets explicit width/height so the box is reserved even before CSS
  # applies (no full-screen balloon on a cold load). `px` is that reserved size;
  # `classes` carry the Tailwind sizing + styling. The navbar logo stays inline
  # — it needs a scroll-responsive x-bind:class the helper can't express.
  def brand_logo(px:, classes: "")
    tag.img(src: "/icon-192.png", alt: "Turf Totals", width: px, height: px,
            class: ["rounded-full", classes].join(" ").strip)
  end

  def format_turf_score(value)
    return "—" unless value
    value == value.to_i ? value.to_i.to_s : sprintf('%.1f', value)
  end

  # Whether to load LogRocket session replay on this request. Replay runs only
  # in production AND never on pages that render secrets — a controller marks
  # those by setting @suppress_session_replay (see WalletExportsController).
  # The wallet-export reveal page renders a decrypted private key into the DOM;
  # without this gate LogRocket would stream that key (and the user's email via
  # identify()) to a third party (Lazarus audit #2, 2026-05-31).
  def session_replay_active?
    Rails.env.production? && !@suppress_session_replay
  end
end
