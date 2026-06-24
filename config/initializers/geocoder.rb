Geocoder.configure(
  ip_lookup: :ipinfo_io,
  # ipinfo.io 301-redirects http -> https with a non-JSON body, and Geocoder
  # does not follow the redirect — a plain-HTTP lookup silently returns no
  # result ("response was not valid JSON"). Without a detected state, the CDP
  # ramp catalog fails closed ("not available in your region") for every US
  # user and the GeoSetting state blocklist stops enforcing. Force HTTPS.
  use_https: true,
  timeout: 3,
  units: :mi
)
