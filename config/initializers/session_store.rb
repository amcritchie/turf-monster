# OPSEC-041 + prelaunch-audit C3: session cookie hardening + hub isolation.
#
# - key: "_turf_session"             — distinct from the SSO hub's _studio_session
#                                      cookie. The hub previously shared the
#                                      cookie via .mcritchie.studio + the same
#                                      key, and the hub did not set
#                                      secure/httponly/same_site on its
#                                      Set-Cookie. That overwrote turf-monster's
#                                      hardened cookie on every cross-app request
#                                      and exposed turf-monster sessions to XSS /
#                                      network MITM via the hub. Pre-mainnet
#                                      decision (2026-05-24): isolate the cookie
#                                      entirely until the hub is hardened.
# - domain: NOT set in prod          — scopes the cookie to turf.mcritchie.studio
#                                      only. Hub's _studio_session cookie is no
#                                      longer readable here, so the SSO
#                                      `session[:sso_email]` etc. fields can't
#                                      flow in either. Combined with the
#                                      SessionsController override that 404s
#                                      `sso_continue` / `sso_login`, the cross-
#                                      app SSO surface is fully closed.
# - secure: true in production       — cookie only sent over HTTPS
# - httponly: true                   — JS can't read the cookie (XSS mitigation)
# - same_site: :lax                  — blocks most CSRF without breaking OAuth bounces
#
# Cookie is signed + encrypted by Rails (default :cookie_store behavior using
# SECRET_KEY_BASE), so tampering is detectable.
#
# To restore SSO later (post-launch, once the hub cookie is hardened): change
# `key:` back to "_studio_session" and re-add `domain: ".mcritchie.studio"` in
# prod. Then revert the SessionsController override and re-add the
# `render "sessions/sso_continue"` call in sessions/new.html.erb.
Rails.application.config.session_store :cookie_store,
  key: "_turf_session",
  secure: Rails.env.production?,
  httponly: true,
  same_site: :lax
