namespace :nfl do
  desc "Recolor existing NFL teams from Nfl::TeamPalette (post-deploy: colors only, never games/slates)"
  task recolor: :environment do
    count = Nfl::TeamPalette.apply!
    puts "nfl:recolor — recolored #{count} team(s) from Nfl::TeamPalette::PALETTE"
  end
end
