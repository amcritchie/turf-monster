# Authentication & Account Management

## Three Auth Methods

All optional — user needs at least one:

- **Email + password** — traditional signup/login via studio engine controllers
- **Google OAuth** — via OmniAuth, links to existing email users automatically
- **Solana wallet (Phantom)** — Ed25519 signature verification, `SolanaSessionsController`

> See [`SIGNUP_FLOWS.md`](SIGNUP_FLOWS.md) for end-to-end sequence diagrams of all three sign-up paths — frontend, backend, third parties, and on-chain.

## User Model Auth Design

```ruby
has_secure_password validations: false  # wallet users have no password
has_one_attached :avatar
validates :email, uniqueness: true, allow_nil: true
validates :username, uniqueness: { case_sensitive: false }, allow_nil: true
validates :username, length: { in: 3..30 }, format: { with: /\A[a-zA-Z0-9_-]+\z/ }, allow_nil: true
validates :password, length: { minimum: 6 }, if: -> { password.present? }
validates :password, confirmation: true, if: -> { password_confirmation.present? }
validate :has_authentication_method  # must have email, solana_address, or provider+uid
```

- `email` is **nullable** — wallet-only users have no email
- `username` — 3-30 chars, alphanumeric + underscore + hyphen, case-insensitive uniqueness, nullable
- `password_digest` keeps `null: false, default: ""` (has_secure_password needs it)
- Predicate helpers: `google_connected?`, `has_password?`, `has_email?`, `profile_complete?` (username present)
- `display_name` fallback chain: username → name → email prefix → truncated_solana → "anon"
- `has_one_attached :avatar` — user profile avatar via Active Storage
- `profile_complete?` — returns `username.present?`, used by `require_profile_completion` before_action
- `require_profile_completion` in ApplicationController — redirects incomplete profiles to `/account/complete_profile` (skips auth routes, API, account completion itself)

## Account Management (`/account`)

- **AccountsController** — show, update, unlink_google, change_password, complete_profile, save_profile, update_username, confirm_username
- **Complete Profile page** (`/account/complete_profile`) — shown when `profile_complete?` is false. Collects username (+ optional avatar). `save_profile` action saves and redirects back to original destination.
- **UserMergeable concern** — merges accounts when linking reveals overlap (lower ID survives)
- **OmniauthCallbacksController** (app override) — merge support when linking Google while logged in. Uses `rescue ActiveRecord::RecordNotUnique` in `from_omniauth` to handle race conditions on concurrent OAuth callbacks.
- Merge transfers entries, sums balances, fills blank auth fields, updates ErrorLog references

## On-Chain Usernames (turf-vault v0.14.0+)

Every user gets an on-chain `UserAccount` PDA with their username stored as a 32-byte UTF-8 field. The DB `username` column mirrors what's on-chain — the chain is the source of truth.

### Signup auto-generation

Two callbacks on `User` set this up eagerly so no user ever has a blank username:

- `before_validation :ensure_username, on: :create` (`user.rb:20`) — fills the DB column with `Studio::UsernameGenerator.generate` if blank.
- `after_commit :enqueue_onchain_account_setup, on: :create` (`user.rb:27`) — enqueues `CreateOnchainUserAccountJob` which calls `Solana::Vault#ensure_user_account(wallet, username:)`. The job is idempotent (skips if the PDA already exists at the current size).

The job runs async via Sidekiq, so users are logged in before the PDA is finalized. Reads of `user.username` always work because the DB column is set first; on-chain lookups should fall back to the DB column when the PDA isn't found yet.

### Editing the username

The `AccountsController` exposes a two-step edit flow because Phantom users must client-side-sign the `set_username` instruction:

- **Managed wallets** — `POST /account/update_username` server-signs immediately via `Solana::Vault#set_username(wallet, new_username, user_keypair:)`. DB column is mirrored in the same request. (`accounts_controller.rb:181-185`)
- **Phantom wallets** — `POST /account/update_username` returns a partial `set_username` TX. Client signs and broadcasts. `POST /account/confirm_username` verifies the TX signature via `verify_solana_transaction!` (OPSEC-010) before mirroring the new username to the DB. (`accounts_controller.rb:159-217`)

The instruction itself (`set_username`) is in turf-vault — the username is padded with `0x00` to 32 bytes on-chain. `Solana::Vault#username_bytes32` (`vault.rb`) handles the encoding.

### Files

- `app/models/user.rb` — callbacks (lines 20, 27, 278-285)
- `app/jobs/create_onchain_user_account_job.rb` — async PDA creation
- `app/controllers/accounts_controller.rb` — edit flow (lines 159-217)
- `app/services/solana/vault.rb` — `ensure_user_account`, `create_user_account`, `set_username`, `build_set_username`, `username_bytes32`
- `studio-engine` — `Studio::UsernameGenerator` (auto-gen helper)

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

## SSO Satellite Role — REMOVED 2026-05-24

> **Effective status: SSO is fully removed from turf-monster** as of the 2026-05-24 pre-launch audit (finding C3). The cookie is isolated, the SSO endpoints return 404, and the UI partial is deleted.

### What was changed
- **Cookie key + scope** (`config/initializers/session_store.rb`): key `_studio_session` → `_turf_session`, `.mcritchie.studio` domain dropped. The hub's shared cookie is no longer readable here, so `session[:sso_email]` etc. cannot flow in.
- **Controller override** (`app/controllers/sessions_controller.rb`): local replacement that 404s `sso_continue` and `sso_login`. Other actions (`new`/`create`/`destroy`) mirror studio-engine's.
- **Login view** (`app/views/sessions/new.html.erb`): `has_sso` reveal overlay logic + `render "sessions/sso_continue"` calls removed.
- **Partial deleted** (`app/views/sessions/_sso_continue.html.erb`).

### Why
The hub (mcritchie-studio) sets `_studio_session` cookie without `secure` / `httponly` / `same_site` flags. Because the cookie was shared with turf-monster (`.mcritchie.studio` domain + same key), the hub's unhardened cookie would overwrite turf-monster's hardened cookie on every cross-app request — making turf-monster sessions stealable via XSS or network MITM on the hub side, then replayable here. The hub also writes `session[:sso_email]` / `[:sso_name]` / `[:sso_provider]` / `[:sso_uid]`, which the engine's `sso_continue` action would consume to silently create or log in a turf-monster user. Closing this attack chain pre-mainnet was a launch-blocker.

### Restoring SSO later
When the hub's `config/initializers/session_store.rb` is hardened (secure/httponly/same_site flags added) and you want cross-app SSO back:
1. Revert `config/initializers/session_store.rb` — key back to `_studio_session`, re-add `domain: ".mcritchie.studio"` in prod.
2. Delete `app/controllers/sessions_controller.rb` (so the engine's SSO actions take over again).
3. Re-render the SSO partial in `app/views/sessions/new.html.erb` — `<%= render "sessions/sso_continue" %>` plus the original `has_sso` reveal overlay.
4. Recreate `app/views/sessions/_sso_continue.html.erb` (or rely on the engine's version — no local override needed).

### Reference: how it worked before
This app received one-way SSO from McRitchie Studio (the hub). Login page showed "Continue as [name]" button when the user was logged into Studio. `GET /sso_login` (the hub's nav-link target) redirected here; sign-in went through the CSRF-protected `POST /sso_continue` (OPSEC-016 — the GET no longer mutated the session). Logout only cleared this app's session. Wallet-only users (no email) couldn't SSO. Hub logo at `public/studio-logo.svg`. Required shared `SECRET_KEY_BASE`.

## Solana Auth Security

- **Nonce replay prevention**: Solana nonces include timestamp, enforced 5-minute expiry window. Nonce is deleted from session before verification (delete-before-verify pattern) to prevent replay attacks.
- **Host binding** (OPSEC-018): the signed message must name the request host as its opening token (`"<host> wants to sign in…"`). `Solana::SessionAuth#verify_solana_signature!` passes `expected_host: request.host_with_port` to the gem's `Solana::AuthVerifier.verify!`, so a signature the user produced for another dApp (with a matching nonce) can't satisfy turf-monster login.

## Account Routes

- `/account` — GET account settings, PATCH update profile
- `/account/complete_profile` — GET, complete profile page
- `/account/save_profile` — POST, save profile completion form
- `/account/unlink_google` — POST, unlink Google OAuth
- `/account/change_password` — POST, set or change password

**Route name gotcha**: `resource :account` with member routes generates `unlink_google_account_path` (not `account_unlink_google_path`). The action name comes first.
