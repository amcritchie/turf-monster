# Presentation colors for team cards. Teams carry raw brand hex in
# color_primary / color_secondary and a color_text_light flag (a light brand
# color that wants dark foreground text, e.g. the gold-forward Saints and
# Steelers). This helper turns those three fields into ready-to-use CSS: a
# team-hue gradient, a readable foreground, and a mascot accent that stays
# legible even when a team's stored secondary is near-black.
module TeamColorsHelper
  DARK_FG          = "#0f1216".freeze # foreground for light-forward cards
  LIGHT_FG         = "#ffffff".freeze # foreground for dark cards
  FALLBACK_PRIMARY = "#3a3f4b".freeze # neutral when a team has no brand color
  # WCAG large-text contrast floor. The mascot is big and bold, so 3:1 is the
  # readable minimum; below it we swap the stored secondary for a team tint.
  ACCENT_MIN_CONTRAST = 3.0

  # Ready-to-use CSS values for one team card. Keys map straight onto inline
  # style attributes in contests/_multi_week_team_card.
  def team_card_palette(team)
    primary   = normalize_hex(team&.color_primary) || FALLBACK_PRIMARY
    secondary = normalize_hex(team&.color_secondary)
    light     = team_text_light?(team)
    fg        = light ? DARK_FG : LIGHT_FG

    {
      gradient: team_gradient(primary, light),
      fg: fg,
      fg_soft: rgba(fg, 0.72),   # city line, week opponents
      fg_faint: rgba(fg, 0.55),  # labels, "Points / Goal"
      border: rgba(fg, 0.18),    # card edge
      divider: rgba(fg, 0.14),   # week-row rules
      accent: team_accent(primary, secondary, light) # the mascot
    }
  end

  # A vertical gradient in the team's own hue. Light-forward teams stay airy;
  # dark teams gain depth toward the bottom.
  def team_gradient(primary, light)
    top    = lighten_hex(primary, light ? 0.12 : 0.06)
    bottom = darken_hex(primary, light ? 0.10 : 0.32)
    "linear-gradient(160deg, #{top} 0%, #{primary} 45%, #{bottom} 100%)"
  end

  # The mascot font color. The curated secondary IS the brand accent, so it is
  # used as-is even when it's a lower-contrast choice (e.g. Bills red on royal
  # blue, 49ers gold on scarlet) — that legibility trade-off is the team's own
  # identity. Only a MISSING secondary falls back to a readable tint of primary.
  def team_accent(primary, secondary, light)
    return secondary if secondary.present?

    readable_tint(primary, prefer_dark: light)
  end

  # Push the primary hue lighter (dark cards) or darker (light cards) until it
  # clears the contrast floor, so the mascot always pops in-hue. Falls to the
  # preferred pole if even that isn't enough.
  def readable_tint(primary, prefer_dark:)
    directions = prefer_dark ? [true, false] : [false, true]
    directions.each do |go_dark|
      (5..9).each do |step|
        amount = step / 10.0
        candidate = go_dark ? darken_hex(primary, amount) : lighten_hex(primary, amount)
        return candidate if contrast_ratio(candidate, primary) >= ACCENT_MIN_CONTRAST
      end
    end
    prefer_dark ? "#000000" : "#ffffff"
  end

  def team_text_light?(team)
    return false unless team.respond_to?(:color_text_light)

    ActiveModel::Type::Boolean.new.cast(team.color_text_light) || false
  end

  # --- pure color math (hex in, css out) ------------------------------------

  def normalize_hex(hex)
    return nil if hex.blank?

    h = hex.to_s.strip.delete_prefix("#")
    h = h.chars.map { |c| c * 2 }.join if h.length == 3
    return nil unless h.match?(/\A[0-9a-fA-F]{6}\z/)

    "##{h.downcase}"
  end

  def hex_to_rgb(hex)
    h = normalize_hex(hex)
    return [0, 0, 0] unless h

    h = h.delete_prefix("#")
    [h[0, 2], h[2, 2], h[4, 2]].map { |pair| pair.to_i(16) }
  end

  def lighten_hex(hex, amount)
    r, g, b = hex_to_rgb(hex)
    rgb_to_hex(r + ((255 - r) * amount), g + ((255 - g) * amount), b + ((255 - b) * amount))
  end

  def darken_hex(hex, amount)
    r, g, b = hex_to_rgb(hex)
    rgb_to_hex(r * (1 - amount), g * (1 - amount), b * (1 - amount))
  end

  def rgba(hex, alpha)
    r, g, b = hex_to_rgb(hex)
    "rgba(#{r}, #{g}, #{b}, #{alpha})"
  end

  # WCAG relative luminance + contrast ratio, used to keep the mascot legible.
  def relative_luminance(hex)
    r, g, b = hex_to_rgb(hex).map do |channel|
      cs = channel / 255.0
      cs <= 0.03928 ? cs / 12.92 : (((cs + 0.055) / 1.055)**2.4)
    end
    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end

  def contrast_ratio(hex1, hex2)
    lum = [relative_luminance(hex1), relative_luminance(hex2)]
    (lum.max + 0.05) / (lum.min + 0.05)
  end

  private

  def rgb_to_hex(r, g, b)
    format("#%02x%02x%02x", clamp255(r), clamp255(g), clamp255(b))
  end

  def clamp255(value)
    value.round.clamp(0, 255)
  end
end
