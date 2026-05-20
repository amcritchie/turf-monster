# Authentication & Account Management

## Three Auth Methods

All optional — user needs at least one:

- **Email + password** — traditional signup/login via studio engine controllers
- **Google OAuth** — via OmniAuth, links to existing email users automatically
- **Solana wallet (Phantom)** — Ed25519 signature verification, `SolanaSessionsController`

## User Model Auth Design

```ruby
has_secure_password validations: false  # wallet users have no password
has_one_attached :avatar
validates :email, uniqueness: true, allow_nil: true
validates :username, uniqueness: { case_sensitive: false }, allow_nil: true
validates :username, length: { in: 3..30 }, format: { with: /\A[a-zA-Z0-9_]+\z/ }, allow_nil: true
validates :password, length: { minimum: 6 }, if: -> { password.present? }
validates :password, confirmation: true, if: -> { password_confirmation.present? }
validate :has_authentication_method  # must have email, solana_address, or provider+uid
```

- `email` is **nullable** — wallet-only users have no email
- `username` — 3-30 chars, alphanumeric + underscore, case-insensitive uniqueness, nullable
- `password_digest` keeps `null: false, default: ""` (has_secure_password needs it)
- Predicate helpers: `google_connected?`, `has_password?`, `has_email?`, `profile_complete?` (username present)
- `display_name` fallback chain: username → name → email prefix → truncated_solana → "anon"
- `has_one_attached :avatar` — user profile avatar via Active Storage
- `profile_complete?` — returns `username.present?`, used by `require_profile_completion` before_action
- `require_profile_completion` in ApplicationController — redirects incomplete profiles to `/account/complete_profile` (skips auth routes, API, account completion itself)

## Account Management (`/account`)

- **AccountsController** — show, update, unlink_google, change_password, complete_profile, save_profile
- **Complete Profile page** (`/account/complete_profile`) — shown when `profile_complete?` is false. Collects username (+ optional avatar). `save_profile` action saves and redirects back to original destination.
- **UserMergeable concern** — merges accounts when linking reveals overlap (lower ID survives)
- **OmniauthCallbacksController** (app override) — merge support when linking Google while logged in. Uses `rescue ActiveRecord::RecordNotUnique` in `from_omniauth` to handle race conditions on concurrent OAuth callbacks.
- Merge transfers entries, sums balances, fills blank auth fields, updates ErrorLog references

## Admin Authorization

- `role` string column on User (default `"viewer"`)
- `admin?` predicate: `role == "admin"`
- `require_admin` before_action in ApplicationController — redirects non-admins to root with alert
- Admin-gated actions on ContestsController: `grade`, `fill`, `lock`, `jump`, `reset`
- Seed admin: `alex@mcritchie.studio` (role: "admin")

## Passwords

- Minimum 6 characters (enforced in model validation)
- Seed/fixture password: `"password"` (not "pass" — too short for min 6 validation)
- `has_secure_password validations: false` disables ALL built-in validations including confirmation — must add `validates :password, confirmation: true` explicitly

## SSO Satellite Role

This app receives one-way SSO from McRitchie Studio (the hub). Login page shows "Continue as [name]" button (from engine's `_sso_continue.html.erb` partial) when user is logged into Studio. `GET /sso_login` (the hub's nav-link target) redirects to this app's login page; sign-in itself goes through the CSRF-protected `POST /sso_continue` button there (OPSEC-016 — the GET no longer mutates the session). Logout only clears this app's session. Wallet-only users (no email) cannot SSO. Hub logo at `public/studio-logo.svg`. Requires shared `SECRET_KEY_BASE`.

## Solana Auth Security

- **Nonce replay prevention**: Solana nonces include timestamp, enforced 5-minute expiry window. Nonce is deleted from session before verification (delete-before-verify pattern) to prevent replay attacks.
- **Host binding** (OPSEC-018): the signed message must name the request host as its opening token (`"<host> wants to sign in…"`). `Solana::SessionAuth#verify_solana_signature!` passes `expected_host: request.host_with_port` to the gem's `Solana::AuthVerifier.verify!`, so a signature the user produced for another dApp (with a matching nonce) can't satisfy turf-monster login.

## Account Routes

- `/account` — GET account settings, PATCH update profile
- `/account/complete_profile` — GET, complete profile page
- `/account/save_profile` — POST, save profile completion form
- `/account/unlink_google` — POST, unlink Google OAuth
- `/account/change_password` — POST, set or change password
- `/account/update_level` — PATCH, update level from seeds

**Route name gotcha**: `resource :account` with member routes generates `unlink_google_account_path` (not `account_unlink_google_path`). The action name comes first.
