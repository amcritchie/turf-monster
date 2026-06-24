require "test_helper"

# Regression guard for config/initializers/geocoder.rb.
#
# ipinfo.io 301-redirects http://ipinfo.io/<ip>/geo -> https with an empty,
# non-JSON body. Geocoder does NOT follow that redirect, so a plain-HTTP lookup
# silently yields "response was not valid JSON" -> no result. When IP
# geolocation fails, geo_state goes blank and geo_country defaults to "US",
# which makes Cdp::Catalog#available? fail closed ("not available in your
# region") for every US user AND silently disables the GeoSetting state
# blocklist (blocked?(nil) == false). The fix is use_https: true; this test
# fails if anyone drops it.
class GeocoderInitializerTest < ActiveSupport::TestCase
  test "geocoder is configured to call ipinfo over HTTPS" do
    assert Geocoder.config.use_https,
           "Geocoder.config.use_https must be true — ipinfo 301-redirects http->https and Geocoder won't follow it"
  end

  test "the ipinfo_io lookup builds an https query URL" do
    assert_equal :ipinfo_io, Geocoder.config.ip_lookup,
                 "expected the IP lookup to stay :ipinfo_io"

    url = Geocoder::Lookup.get(:ipinfo_io).send(:query_url, Geocoder::Query.new("8.8.8.8"))
    assert url.start_with?("https://"),
           "ipinfo lookup must use https (plain http 301-redirects to a non-JSON body); got #{url}"
  end
end
