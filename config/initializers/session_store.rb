# OPSEC-041: session cookie hardening.
#
# - secure: true in production       — cookie only sent over HTTPS
# - httponly: true                   — JS can't read the cookie (XSS mitigation)
# - same_site: :lax                  — blocks most CSRF without breaking OAuth bounces
# - domain: .mcritchie.studio in prod — shared with the SSO hub (mcritchie-studio)
#
# Cookie is signed + encrypted by Rails (default :cookie_store behavior using
# SECRET_KEY_BASE), so tampering is detectable. The :secure + :httponly +
# :same_site triad covers the network-layer XSS / CSRF attack surface that
# OPSEC-041 flagged.
Rails.application.config.session_store :cookie_store,
  key: "_studio_session",
  domain: (Rails.env.production? ? ".mcritchie.studio" : :all),
  secure: Rails.env.production?,
  httponly: true,
  same_site: :lax
