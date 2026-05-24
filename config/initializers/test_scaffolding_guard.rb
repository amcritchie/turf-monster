# Hard-fail boot in production if ENABLE_TEST_SCAFFOLDING is on.
#
# The flag unlocks the $1 "micro" contest tier and the $5 / 3-token bundle
# (see AppFlags.test_scaffolding? and the TEST_PACK_IDS / TEST_FORMAT_KEYS
# constants in StripePurchase / Contest). Off by default everywhere; intended
# for dev + QA only. Crashing on boot is intentional: any production deploy
# that accidentally carries the flag fails loudly instead of quietly handing
# attackers $1.67-per-token entry tokens.
Rails.application.config.after_initialize do
  if Rails.env.production? && AppFlags.test_scaffolding?
    raise "ENABLE_TEST_SCAFFOLDING is enabled in production. Unset this env " \
          "var (heroku config:unset ENABLE_TEST_SCAFFOLDING --app turf-monster) " \
          "before deploying."
  end
end
