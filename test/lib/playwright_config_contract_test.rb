require "test_helper"

# Contract: the e2e webServer boot budget must cover db:test:prepare + the
# e2e seed (which caches the full NFL 2026 team totals since 2026-07) + rails
# server boot on a slow CI runner. The prior 30s budget was marginal and
# red-flaked playwright shard 1 twice in two days (runs 29692136014 and
# 29720145697), both timing out directly after the NFL cache seed line. Guard
# the floor so it cannot quietly regress.
class PlaywrightConfigContractTest < ActiveSupport::TestCase
  CONFIG_PATH = Rails.root.join("playwright.config.js")

  test "webServer timeout floor covers the seeded boot" do
    timeout = CONFIG_PATH.read[/timeout:\s*([\d_]+)/, 1]

    assert timeout, "webServer timeout not found in playwright.config.js"
    assert_operator timeout.delete("_").to_i, :>=, 120_000
  end
end
