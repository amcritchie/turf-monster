# frozen_string_literal: true

data_path = Rails.root.join("db/seeds/data/nfl_2026_weeks_1_17.json")
data = JSON.parse(File.read(data_path))

puts "  Loading NFL #{data.fetch("season")} schedule from #{data.fetch("generated_at")}"

NFL_TEAM_EMOJIS = {
  "ARI" => "🐦",
  "ATL" => "🦅",
  "BAL" => "🐦‍⬛",
  "BUF" => "🦬",
  "CAR" => "🐆",
  "CHI" => "🐻",
  "CIN" => "🐅",
  "CLE" => "🐶",
  "DAL" => "🤠",
  "DEN" => "🐴",
  "DET" => "🦁",
  "GB" => "🧀",
  "HOU" => "🐂",
  "IND" => "🐎",
  "JAX" => "🐆",
  "KC" => "🏹",
  "LAC" => "⚡",
  "LAR" => "🐏",
  "LV" => "☠️",
  "MIA" => "🐬",
  "MIN" => "🛡️",
  "NE" => "🇺🇸",
  "NO" => "⚜️",
  "NYG" => "🗽",
  "NYJ" => "✈️",
  "PHI" => "🦅",
  "PIT" => "⚙️",
  "SEA" => "🌊",
  "SF" => "⛏️",
  "TB" => "🏴‍☠️",
  "TEN" => "⚔️",
  "WSH" => "🪖"
}.freeze

nfl_teams = {}
data.fetch("teams").each do |row|
  abbreviation = row.fetch("abbreviation")
  team = Team.find_or_initialize_by(slug: row.fetch("display_name").parameterize)
  team.assign_attributes(
    name: row.fetch("display_name"),
    short_name: abbreviation,
    location: row.fetch("location"),
    emoji: NFL_TEAM_EMOJIS.fetch(abbreviation, "\u{1F3C8}"),
    color_primary: row.fetch("color_primary"),
    color_secondary: row.fetch("color_secondary")
  )
  team.save!
  nfl_teams[abbreviation] = team
end

games_by_week = Hash.new { |hash, week| hash[week] = [] }

data.fetch("games").each do |row|
  home_team = nfl_teams.fetch(row.fetch("home"))
  away_team = nfl_teams.fetch(row.fetch("away"))
  kickoff_at = Time.zone.parse(row.fetch("starts_at"))
  venue = [row.fetch("venue"), row.fetch("location")].reject(&:blank?).join(", ")
  game_slug = "#{home_team.slug}-vs-#{away_team.slug}"

  game = Game.find_or_initialize_by(slug: game_slug)
  game.assign_attributes(
    home_team_slug: home_team.slug,
    away_team_slug: away_team.slug,
    kickoff_at: kickoff_at,
    venue: venue
  )
  game.status = "scheduled" if game.status.blank?
  game.save!

  games_by_week[row.fetch("week")] << { game: game, home_team: home_team, away_team: away_team }
end

games_by_week.sort.each do |week, entries|
  first_game_at = entries.map { |entry| entry.fetch(:game).kickoff_at }.compact.min
  slate = Slate.find_or_initialize_by(name: "NFL 2026 Week #{week}")
  slate.starts_at = first_game_at
  slate.save!

  entries.each do |entry|
    game = entry.fetch(:game)
    home_team = entry.fetch(:home_team)
    away_team = entry.fetch(:away_team)

    [[home_team, away_team], [away_team, home_team]].each do |team, opponent|
      matchup = SlateMatchup.find_or_initialize_by(slate: slate, team_slug: team.slug)
      matchup.assign_attributes(
        opponent_team_slug: opponent.slug,
        game_slug: game.slug
      )
      matchup.save!
    end
  end

  sorted_matchups = slate.slate_matchups.includes(:team, :game).sort_by do |matchup|
    [matchup.game&.kickoff_at || first_game_at, matchup.team.name]
  end

  sorted_matchups.each_with_index do |matchup, index|
    rank = index + 1
    matchup.update!(rank: rank, turf_score: SlateMatchup.turf_score_for(rank, sorted_matchups.size))
  end

  puts "  Created slate: #{slate.name} (#{entries.size} games, #{slate.slate_matchups.count} matchups, starts #{first_game_at.utc.iso8601})"
end

puts "  Created NFL #{data.fetch("season")} teams/games/slates (#{nfl_teams.size} teams, #{data.fetch("games").size} games, #{games_by_week.size} slates)"
