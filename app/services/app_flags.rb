# Central accessor for environment feature flags.
#
# test_scaffolding? gates throwaway, test-only options that must be DISABLED
# before the public production launch:
#   - the $1 "micro" contest tier   (see Contest::FORMATS / Contest.selectable_formats)
#   - the $5 / 3-token entry bundle  (see StripePurchase::PACKS / .available_packs)
#
# Off by default everywhere — including production — unless the operator sets
# ENABLE_TEST_SCAFFOLDING=true. To disable before launch, unset the env var.
#
# cdp_ramp? gates the Coinbase CDP Onramp/Offramp integration (buy USDC /
# cash out via the Coinbase-hosted widget) — routes, controllers, and all UI
# entry points. Off by default everywhere; unsetting ENABLE_CDP_RAMP is the
# kill-switch. See docs/CDP_RAMP_INTEGRATION.md §2.
module AppFlags
  # True when test-only scaffolding (micro tier, $5 token bundle) is enabled.
  def self.test_scaffolding?
    ENV["ENABLE_TEST_SCAFFOLDING"].to_s.strip.downcase == "true"
  end

  # True when the Coinbase CDP Onramp/Offramp (buy / cash out USDC) is enabled.
  def self.cdp_ramp?
    ENV["ENABLE_CDP_RAMP"].to_s.strip.downcase == "true"
  end
end
