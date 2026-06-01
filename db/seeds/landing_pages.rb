# ─── Landing pages (marketing funnels) ───────────────────────
# Idempotent upsert by slug — safe to re-run; the seed is the source of truth
# for each page's copy/background.
#
# Contest linkage: contests are NOT seeded (see the note in db/seeds.rb — they're
# created intentionally at GTM time), and contest IDs aren't stable across
# reseeds, so each funnel references its target contest BY SLUG. A page is set
# active ONLY when that contest exists (LandingPage#contest_required_when_active
# rejects active without a contest); otherwise it seeds as an admin-previewable
# DRAFT until the operator wires a contest + flips it live via /admin/landing_pages.
#
# Public funnel URL: /l/:slug.
#
# NOTE: "alpha" has no dedicated seeded contest (it pointed at a throwaway test
# contest in dev). It targets the World Cup contest its copy references; if you
# create a real Alpha contest, update its :contest_slug below.
puts "Seeding landing pages..."

LANDING_PAGES = [
  {
    slug: "alpha",
    name: "Turf Totals Alpha Contest",
    headline: "World Cup Alpha Contest ⚽️",
    subheadline: "Thanks for joining the Turf Totals Alpha Contest. Each submission into the Alpha test will get you a free entry ticket into the World Cup Week 1 Group Stage contest. Pick 6 matchups, ride the multipliers, and win!",
    badge: "Alpha Access",
    cta_label: "Claim Your Alpha Spot",
    background_style: "blobs",
    contest_slug: "world-cup-2026"
  },
  {
    slug: "world-cup-week-1",
    name: "Turf Totals — World Cup Week 1 Group Play",
    headline: "World Cup Week 1 — Group Stage",
    subheadline: "Six group-stage picks. Goals × Turf Score. Lock your lineup before the opening whistle.",
    badge: "Group Stage",
    cta_label: "Make Your Picks",
    background_style: "circles",
    contest_slug: "world-cup-2026"
  }
].freeze

LANDING_PAGES.each do |attrs|
  contest = Contest.find_by(slug: attrs[:contest_slug])

  page = LandingPage.find_or_initialize_by(slug: attrs[:slug])
  page.assign_attributes(
    name:             attrs[:name],
    headline:         attrs[:headline],
    subheadline:      attrs[:subheadline],
    badge:            attrs[:badge],
    cta_label:        attrs[:cta_label],
    background_style: attrs[:background_style],
    contest:          contest,
    active:           contest.present? # can't be active without a contest (model validation)
  )
  page.save!

  state = page.active? ? "active → #{contest.slug}" : "draft (awaiting contest #{attrs[:contest_slug].inspect})"
  puts "  /l/#{page.slug} — #{state}"
end
