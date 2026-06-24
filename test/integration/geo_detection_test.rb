require "test_helper"

# Integration coverage across the geo-detection I/O boundary (the ipinfo HTTP
# lookup, mocked here at Geocoder.search). Proves that once a lookup succeeds,
# the real detect_geo_state -> normalize_state_code -> GeoSetting blocklist
# pipeline fires end-to-end through GET /geo/check.
#
# The shipped bug (config/initializers/geocoder.rb without use_https) was that
# the lookup ITSELF returned nothing — ipinfo 301-redirects plain HTTP to a
# non-JSON body and Geocoder won't follow it — so geo_state stayed blank, the
# CDP ramp catalog fell to its US-needs-a-subdivision fail-closed branch, and
# the state blocklist silently stopped enforcing. The "no result" case below
# pins that exact failure mode.
class GeoDetectionTest < ActionDispatch::IntegrationTest
  GeoResult = Struct.new(:country_code, :state_code, :region_code, :region, keyword_init: true)

  setup do
    @geo = GeoSetting.current
    @geo.update!(enabled: true, banned_states: %w[WA ID MT])
  end

  test "a resolved ipinfo region normalizes to its 2-letter state code" do
    # ipinfo-via-Geocoder returns the full region name with a blank state_code.
    result = GeoResult.new(country_code: "US", state_code: "", region_code: nil, region: "California")
    Geocoder.stub :search, [result] do
      get geo_check_path
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "CA", body["state"]
    assert_equal false, body["blocked"], "California is not in this fixture's banned list"
  end

  test "a resolved banned state is blocked once geo detection works" do
    result = GeoResult.new(country_code: "US", state_code: "WA", region_code: nil, region: "Washington")
    Geocoder.stub :search, [result] do
      get geo_check_path
    end
    body = JSON.parse(response.body)
    assert_equal "WA", body["state"]
    assert_equal true, body["blocked"], "the WA blocklist must enforce when geo resolves"
  end

  test "a failed lookup (the http-301 regression) leaves state blank and the blocklist silently open" do
    Geocoder.stub :search, [] do
      get geo_check_path
    end
    body = JSON.parse(response.body)
    assert_nil body["state"]
    assert_equal false, body["blocked"], "documents why the broken lookup was a compliance hazard, not just a UX bug"
  end
end
