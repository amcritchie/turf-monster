Geocoder.configure(
  ip_lookup: :ipinfo_io,
  # Authenticated ipinfo lifts the anonymous-tier rate limit. Under load the
  # free/anonymous endpoint starts returning no region (or 429s), which makes
  # geo_state blank — failing the CDP ramp closed ("not available in your
  # state") for every US user, the only funding rail when Stripe is disabled.
  # A blank/nil token is a safe no-op (the anonymous tier, today's behavior),
  # so this is dormant until IPINFO_API_TOKEN is set in the environment.
  ipinfo_io: { api_key: ENV["IPINFO_API_TOKEN"].presence },
  # ipinfo.io 301-redirects http -> https with a non-JSON body, and Geocoder
  # does not follow the redirect — a plain-HTTP lookup silently returns no
  # result ("response was not valid JSON"). Without a detected state, the CDP
  # ramp catalog fails closed ("not available in your region") for every US
  # user and the GeoSetting state blocklist stops enforcing. Force HTTPS.
  use_https: true,
  timeout: 3,
  units: :mi
)
