# frozen_string_literal: true

# Host override of studio-engine's Studio::UsernameGenerator.
#
# studio-engine ships a generator that emits "[fruit/veg]-[animal]" names via
# Faker (e.g. "iceberg-lettuce-raccoon"). Turf Monster wants friendlier,
# single-word-each handles of the shape "[adjective]-[fruit/veg/plant]"
# (e.g. "crispy-apple", "golden-carrot", "wild-basil").
#
# studio-engine is a NON-isolated engine whose lib/studio.rb does
# `require "studio/username_generator"` at load time, so the gem's version of
# the class is already defined by the time initializers run. We REOPEN and
# fully replace its methods + constants here, so this definition wins
# deterministically (and stays out of Zeitwerk's autoload path).
#
# This is the SINGLE SOURCE OF TRUTH for auto-generated usernames across every
# signup path — magic-link, Google OAuth, and Solana wallet — because all of
# them funnel through User#ensure_username, which calls
# Studio::UsernameGenerator.generate.

module Studio
  class UsernameGenerator
    # Friendly, family-appropriate one-word adjectives. Curated to combine
    # cleanly with any noun below (no crude pairings).
    ADJECTIVES = %w[
      crispy golden wild sunny bold mellow zesty bright cozy swift
      brave lucky jolly fresh rustic happy gentle merry breezy chipper
      cheery dapper plucky snappy spry peppy nimble jaunty perky witty
      clever cosmic stellar lunar solar mighty noble regal royal grand
      humble honest loyal eager keen quick fleet rapid speedy turbo
      vivid radiant glowing shimmer dazzling sparkling gleaming beaming
      rosy ruby amber emerald jade coral pearl ivory crimson scarlet
      azure indigo violet cobalt teal minty leafy earthy woodsy
      frosty wintry autumn vernal summery balmy tropic toasty smoky
      velvet silky satin downy fluffy fuzzy snug comfy candied
      sugary spiced honeyed buttery creamy nutty tangy juicy ripe lush
      hearty wholesome dandy spiffy nifty groovy brisk hushed
      calm serene placid tranquil quiet soft warm kind sweet bubbly
      dashing gallant valiant heroic epic legend mythic stout sturdy
      rugged hardy robust sound spruce trim tidy neat polished
      starlit moonlit dawning rising soaring gliding drifting roaming
    ].uniq.freeze

    # One-word fruits, vegetables, and plants. Multi-word entries
    # (e.g. "juniper berries", "honeydew melon") are intentionally excluded —
    # every entry here is a single word.
    NOUNS = %w[
      apple mango carrot basil fern maple pear plum kale sage
      olive cedar poppy lotus melon peach cherry lemon lime grape
      berry fig date guava papaya apricot quince currant raisin
      banana orange tangerine clementine kiwi lychee passionfruit
      pomegranate persimmon nectarine plantain coconut almond walnut
      pecan hazelnut chestnut acorn pumpkin squash zucchini cucumber
      tomato pepper radish turnip beet parsnip celery spinach lettuce
      cabbage broccoli cauliflower asparagus artichoke leek onion
      garlic shallot ginger turmeric pea bean lentil chickpea
      corn potato yam taro cassava okra eggplant
      thyme rosemary oregano parsley cilantro dill mint chive fennel
      tarragon lavender chamomile jasmine marigold daisy tulip rose
      lily orchid iris peony dahlia aster zinnia petunia begonia
      sunflower clover heather ivy moss reed willow birch aspen
      oak pine spruce fir elm beech alder hazel rowan hawthorn
      bamboo palm cactus aloe succulent juniper cypress
      laurel myrtle holly magnolia dogwood redwood sequoia
      yarrow sorrel nettle thistle bramble bracken sedge rush vine
      cranberry blueberry raspberry blackberry strawberry mulberry
      gooseberry elderberry cantaloupe rhubarb watercress arugula
      cumin saffron clove nutmeg cardamom anise paprika vanilla
    ].uniq.freeze

    def self.generate
      2.times do
        candidate = build_name
        return candidate unless User.exists?(username: candidate)
      end
      "#{build_name}-#{rand(1000..9999)}"
    end

    def self.build_name
      "#{ADJECTIVES.sample}-#{NOUNS.sample}"
    end

    def self.sanitize(str)
      str.downcase.gsub(/[^a-z0-9]/, "-").gsub(/-+/, "-").gsub(/^-|-$/, "")
    end
  end
end
