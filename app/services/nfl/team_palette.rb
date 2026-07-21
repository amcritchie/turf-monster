module Nfl
  # Single source of truth for NFL team brand colors. Both the NFL seed and the
  # `nfl:recolor` post-deploy task read PALETTE, so a color change reaches
  # production by recoloring EXISTING team rows — without re-running the games /
  # slates seed, which would re-freeze live turf_scores and re-price open picks.
  #
  #   primary    → card background
  #   secondary  → the distinctive accent used for the mascot text
  #   alt_light  → the team's light neutral (usually white); "" = none
  #   alt_dark   → the team's dark neutral (usually black/navy); "" = none
  #   text_light → true only for a LIGHT primary that wants dark foreground text
  # Sourced from teamcolorcodes.com; Saints/Steelers kept light-forward.
  module TeamPalette
    PALETTE = {
      "ARI" => { primary: "#97233F", secondary: "#FFB612", alt_light: "#FFFFFF", alt_dark: "#000000" },
      "ATL" => { primary: "#A71930", secondary: "#000000", alt_light: "#FFFFFF", alt_dark: "" },
      "BAL" => { primary: "#241773", secondary: "#9E7C0C", alt_light: "#C60C30", alt_dark: "#000000" },
      "BUF" => { primary: "#00338D", secondary: "#C60C30", alt_light: "#FFFFFF", alt_dark: "#041E42" },
      "CAR" => { primary: "#0085CA", secondary: "#101820", alt_light: "#FFFFFF", alt_dark: "" },
      "CHI" => { primary: "#0B162A", secondary: "#C83803", alt_light: "#FFFFFF", alt_dark: "" },
      "CIN" => { primary: "#FB4F14", secondary: "#000000", alt_light: "#FFFFFF", alt_dark: "" },
      "CLE" => { primary: "#311D00", secondary: "#FF3C00", alt_light: "#FFFFFF", alt_dark: "" },
      "DAL" => { primary: "#003594", secondary: "#869397", alt_light: "#FFFFFF", alt_dark: "#041E42" },
      "DEN" => { primary: "#FB4F14", secondary: "#002244", alt_light: "#FFFFFF", alt_dark: "" },
      "DET" => { primary: "#0076B6", secondary: "#B0B7BC", alt_light: "#FFFFFF", alt_dark: "#000000" },
      "GB"  => { primary: "#203731", secondary: "#FFB612", alt_light: "#FFFFFF", alt_dark: "" },
      "HOU" => { primary: "#03202F", secondary: "#A71930", alt_light: "#FFFFFF", alt_dark: "" },
      "IND" => { primary: "#002C5F", secondary: "#FFFFFF", alt_light: "", alt_dark: "" },
      "JAX" => { primary: "#006778", secondary: "#D7A22A", alt_light: "#FFFFFF", alt_dark: "#101820" },
      "KC"  => { primary: "#E31837", secondary: "#FFB81C", alt_light: "#FFFFFF", alt_dark: "" },
      "LAC" => { primary: "#0080C6", secondary: "#FFC20E", alt_light: "#FFFFFF", alt_dark: "" },
      "LAR" => { primary: "#003594", secondary: "#FFA300", alt_light: "#FFFFFF", alt_dark: "" },
      "LV"  => { primary: "#000000", secondary: "#A5ACAF", alt_light: "", alt_dark: "" },
      "MIA" => { primary: "#008E97", secondary: "#FC4C02", alt_light: "#FFFFFF", alt_dark: "#005778" },
      "MIN" => { primary: "#4F2683", secondary: "#FFC62F", alt_light: "#FFFFFF", alt_dark: "#000000" },
      "NE"  => { primary: "#002244", secondary: "#C60C30", alt_light: "#B0B7BC", alt_dark: "" },
      "NO"  => { primary: "#D3BC8D", secondary: "#101820", alt_light: "#FFFFFF", alt_dark: "", text_light: true },
      "NYG" => { primary: "#0B2265", secondary: "#A71930", alt_light: "#FFFFFF", alt_dark: "" },
      "NYJ" => { primary: "#125740", secondary: "#FFFFFF", alt_light: "", alt_dark: "" },
      "PHI" => { primary: "#004C54", secondary: "#A5ACAF", alt_light: "#FFFFFF", alt_dark: "#000000" },
      "PIT" => { primary: "#FFB612", secondary: "#101820", alt_light: "#FFFFFF", alt_dark: "", text_light: true },
      "SEA" => { primary: "#002244", secondary: "#69BE28", alt_light: "#A5ACAF", alt_dark: "" },
      "SF"  => { primary: "#AA0000", secondary: "#B3995D", alt_light: "#FFFFFF", alt_dark: "#000000" },
      "TB"  => { primary: "#D50A0A", secondary: "#B1BABF", alt_light: "#FF7900", alt_dark: "#3E3C3B" },
      "TEN" => { primary: "#0C2340", secondary: "#4B92DB", alt_light: "#FFFFFF", alt_dark: "" },
      "WAS" => { primary: "#5A1414", secondary: "#FFB612", alt_light: "#FFFFFF", alt_dark: "" }
    }.freeze

    # The color attributes for one PALETTE row, ready for assign_attributes /
    # update!. "" collapses to nil so a blank alt stores as NULL.
    def self.attributes_for(abbr)
      colors = PALETTE.fetch(abbr)
      {
        color_primary: colors[:primary],
        color_secondary: colors[:secondary],
        color_alt_light: colors[:alt_light].to_s.presence,
        color_alt_dark: colors[:alt_dark].to_s.presence,
        color_text_light: colors.fetch(:text_light, false)
      }
    end

    # Upsert ONLY the color columns onto existing NFL team rows (matched by
    # short_name WITHIN the nfl scope, so a same-abbreviation non-NFL team can
    # never be recolored). Safe for production: touches no games, slates, or
    # rankings — and no non-NFL rows. ATOMIC: all 32 updates commit together or
    # not at all, so a mid-run failure never leaves a half-recolored league.
    # Returns the number of teams recolored.
    def self.apply!(scope = Team.nfl)
      ActiveRecord::Base.transaction do
        PALETTE.keys.count do |abbr|
          team = scope.find_by(short_name: abbr)
          team&.update!(attributes_for(abbr)) ? true : false
        end
      end
    end
  end
end
