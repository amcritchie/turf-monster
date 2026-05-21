# Curated contest + landing-page bundles the operator can one-click provision
# from the contest generator page (ContestsController#generate_bundle).
#
# generate! is idempotent (find_or_create) — re-running is safe. A newly
# created contest builds its on-chain PDA via Contest's after_create callback
# (server-funded — Alex Bot funds the prize pool).
module ContestBundle
  ALL = {
    "alpha" => {
      label: "Turf Totals Alpha",
      contest: {
        name: "Turf Totals Alpha Contest",
        game_type: "turf_totals",
        contest_type: "medium",
        slate_name: "World Cup 2026 Group 1"
      },
      landing_page: {
        slug: "alpha",
        name: "Turf Totals Alpha Contest",
        headline: "FIFA World Cup Fantasy Contest",
        subheadline: "Draft Six Teams from the Opening Slate of FIFA World Cup Group Play. Climb the Leaderboard as your teams score points.",
        badge: "Alpha Test",
        cta_label: "Enter the Alpha Contest",
        background_style: "blobs"
      }
    },
    "survivor" => {
      label: "World Cup Survivor Free Roll",
      contest: {
        name: "World Cup Survivor Free Roll",
        game_type: "world_cup_survivor",
        contest_type: "survivor_wc_free",
        slate_name: nil
      },
      landing_page: {
        slug: "survivor",
        name: "World Cup Survivor Free Roll",
        headline: "Last One Standing Wins",
        subheadline: "Pick a team each round of the World Cup. Win or draw to survive. Outlast everyone to take the pot.",
        badge: nil,
        cta_label: "Enter the Free Roll",
        background_style: "gradient"
      }
    },
    "world_cup" => {
      label: "World Cup $1,000",
      contest: {
        name: "World Cup $1000 Turf Total Contest",
        game_type: "turf_totals",
        contest_type: "large",
        slate_name: "World Cup 2026 Group 1"
      },
      landing_page: {
        slug: "world-cup",
        name: "World Cup $1000 Contest",
        headline: "Win $1,000 at the World Cup",
        subheadline: "Draft six teams from the opening slate of FIFA World Cup group play. Top score takes the $1,000 grand prize.",
        badge: nil,
        cta_label: "Enter the $1,000 Contest",
        background_style: "circles"
      }
    }
  }.freeze

  # Idempotently provision a bundle: its contest (+ on-chain PDA on create)
  # and its landing page. Returns { contest:, landing_page: }.
  def self.generate!(key, creator: nil)
    spec = ALL[key]
    raise ArgumentError, "Unknown bundle: #{key.inspect}" unless spec

    contest = find_or_create_contest(spec[:contest], creator)
    landing = find_or_create_landing_page(spec[:landing_page], contest)
    { contest: contest, landing_page: landing }
  end

  def self.find_or_create_contest(spec, creator)
    Contest.find_or_create_by!(name: spec[:name]) do |c|
      slate = resolve_slate(spec[:slate_name])
      format = Contest::FORMATS[spec[:contest_type]] || {}
      c.game_type       = spec[:game_type]
      c.contest_type    = spec[:contest_type]
      c.slate           = slate
      c.status          = "open"
      c.entry_fee_cents = format[:entry_fee_cents]
      c.max_entries     = format[:max_entries]
      c.starts_at       = slate&.starts_at
      c.user            = creator
    end
  end

  def self.find_or_create_landing_page(spec, contest)
    LandingPage.find_or_create_by!(slug: spec[:slug]) do |l|
      l.name             = spec[:name]
      l.headline         = spec[:headline]
      l.subheadline      = spec[:subheadline]
      l.badge            = spec[:badge]
      l.cta_label        = spec[:cta_label]
      l.background_style = spec[:background_style]
      l.contest          = contest
      l.active           = true
    end
  end

  def self.resolve_slate(slate_name)
    return nil if slate_name.blank?

    Slate.find_by(name: slate_name) ||
      raise("Slate #{slate_name.inspect} not found — run db:seed first")
  end
end
