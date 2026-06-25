require "test_helper"

# Unit coverage for ApplicationController.geo_stale? — the freshness policy that
# fixes the stale-blank funding lock-out.
#
# THE BUG: detect_geo_state cached EVERY lookup (including a blank one) for 24h.
# A single transient ipinfo failure (timeout / anonymous rate-limit / outage)
# left geo_state blank but stamped the session "freshly detected", so it would
# not re-attempt for a day. geo_blocked? then fails closed (US + blank state),
# disabling "Buy USDC" — the only funding rail when Stripe is off — for an
# allowed-state user until their IP changed or 24h passed.
#
# THE FIX: a resolved state is trusted for GEO_TTL (a day); a BLANK result is
# only trusted for GEO_RETRY_TTL (minutes) so it self-heals on the next request.
class GeoStalenessTest < ActiveSupport::TestCase
  def stale?(detected_at:, state_present:, now: Time.current)
    ApplicationController.geo_stale?(
      detected_at: detected_at,
      state_present: state_present,
      now: now
    )
  end

  test "a missing detection timestamp is always stale" do
    assert stale?(detected_at: nil, state_present: true)
    assert stale?(detected_at: "", state_present: false)
  end

  test "a resolved state is trusted for ~a day" do
    now = Time.current
    assert_not stale?(detected_at: (now - 1.hour).to_s,   state_present: true, now: now)
    assert_not stale?(detected_at: (now - 23.hours).to_s, state_present: true, now: now)
    assert     stale?(detected_at: (now - 25.hours).to_s, state_present: true, now: now)
  end

  test "a blank result re-detects within minutes (the lock-out fix)" do
    now = Time.current
    # 10 minutes is deep inside the 24h window the buggy code trusted — back then
    # this was NOT stale and the blank stuck for a day. It must now be stale.
    assert stale?(detected_at: (now - 10.minutes).to_s, state_present: false, now: now),
      "a cached blank must re-detect within minutes, not be trusted for 24h"
  end

  test "a just-attempted blank throttles briefly before retrying" do
    now = Time.current
    # ...but not so eagerly that every page load hammers the ipinfo endpoint.
    assert_not stale?(detected_at: (now - 30.seconds).to_s, state_present: false, now: now),
      "a blank attempted seconds ago should wait out the retry window first"
  end
end
