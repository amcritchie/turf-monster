# Sign-Up Flows

Visual companion to [`AUTH.md`](AUTH.md) — how Turf Monster's three sign-up paths span
**frontend**, **backend**, **third parties**, and the **Solana chain**.

_Generated 2026-05-20. For auth security internals (nonce replay, host binding, account merge) see [`AUTH.md`](AUTH.md)._

## TL;DR

- **Three independent entry controllers, one shared spine.** `SolanaSessionsController`,
  `OmniauthCallbacksController`, and `RegistrationsController` share no code — what unifies them
  is the `User` model: `after_create :generate_managed_wallet!` plus the `set_app_session` helper.
- **The Solana chain is never contacted during sign-up** — even on the Phantom/web3 path.
  Signature verification is pure `ed25519`-gem math on the server; `OPSEC-044` deliberately
  removed the one on-chain call.
- **Every user gets a server-held managed wallet** — including Phantom users, who end up with
  *both* their own wallet and a managed one. Admins are the only exception.

## Overview

```
                  FRONTEND                 THIRD PARTY              BACKEND (Rails)
                  ───────────────────      ────────────────────     ─────────────────────────────

  PHANTOM  web3   Alpine: connect       →  Phantom signs the    →   SolanaSessionsController#verify
                  + sign SIWS message      message (ed25519)

  GOOGLE   oauth  button_to POST        →  Google OAuth +       →   OmniAuth middleware  →
                  /auth/google_oauth2      tokeninfo recheck         OmniauthCallbacksController#create

  MANUAL   email  form POST /signup     →  (no third party)     →   RegistrationsController#create
                  email only (no pwd)

                          ALL THREE CONVERGE ON THE SAME SPINE
                                          │
                                          ▼
   User#after_create :generate_managed_wallet!         set_app_session
     - Solana::Keypair.generate (local ed25519)          - session[:turf_user_id]
     - encrypt with MANAGED_WALLET_ENCRYPTION_KEY         - session[:session_token]
     - UPDATE users -> web2_solana_address                => logged in (Rails cookie)
                                          │
                                          ▼
   ON-CHAIN (Solana)   not touched by any sign-up. The managed wallet exists only as
                       encrypted bytes in Postgres until a later funding / contest entry.
```

## The shared spine

Once any of the three controllers has a `User` row, the rest is identical:

1. **`before_validation :ensure_username, on: :create`** (`user.rb:20`) — auto-fills the DB `username` column via `Studio::UsernameGenerator.generate` if blank. Guarantees no user ever has a blank username.
2. **`before_create :set_initial_session_token`** — writes `users.session_token`
   (`SecureRandom.hex(32)`), the OPSEC-045 cookie-binding token.
3. **`after_create :generate_managed_wallet!`** (`app/models/user.rb:237`) — unless the user is
   an admin, generates a custodial Solana keypair via `Solana::Keypair.generate` (local ed25519,
   **no RPC**), encrypts the secret key with a key derived from `MANAGED_WALLET_ENCRYPTION_KEY`,
   and writes `web2_solana_address` + `encrypted_web2_solana_private_key`.
4. **`after_commit :enqueue_onchain_account_setup, on: :create`** (`user.rb:27`) — enqueues `CreateOnchainUserAccountJob`, which calls `Solana::Vault#ensure_user_account(wallet, username:)` to create the on-chain `UserAccount` PDA with the username eagerly. **Async** — users are logged in before the PDA is finalized; reads of `user.username` always work because the DB column is set in step 1. See `docs/AUTH.md` § On-Chain Usernames.
5. **`set_app_session(user)`** — writes the Rails cookie session (`session[:turf_user_id]`,
   `session[:session_token]`, SSO-awareness fields). No DB session row, no JWT.

There is no `Session`, `Wallet`, or `Identity` table — everything hangs off `users`.

**Post-signup redirect (all 3 flows)**: lands on `tokens_buy_path` (the entry-tokens upsell modal), not the root. Wired in `registrations_controller.rb:17`, `omniauth_callbacks_controller.rb:104`, and `solana_sessions_controller.rb:52`.

**Age attestation (all 3 flows — flag-gated, parked OFF)**: when `ENABLE_AGE_ATTESTATION=true` (`AppFlags.age_attestation?`), a legal-age checkbox (`shared/_age_attestation`) gates every signup surface, each controller rejects new signups without it (`age_attestation_required? && !age_attestation_given?`), and `age_attested_at` is stamped on the new row. **Currently unset in prod = OFF** (operator call 2026-06-10, re-enabled after the first contest): the checkbox doesn't render, all gates pass, and `age_attested_at` is deliberately NOT stamped. See `docs/AUTH.md` § Legal-Age Attestation.

**Reference attribution (all 3 flows)**: a 30-day `cookies[:reference]` set by `LandingPagesController#show` (`app/controllers/landing_pages_controller.rb:18`) or `ApplicationController#capture_reference` (`application_controller.rb:51-56`) is persisted onto `users.reference` at signup. Phantom captures it inline at user-build (`solana_sessions_controller.rb:37-42`); Google updates the column post-create and deletes the cookie (`omniauth_callbacks_controller.rb:95-98`); Manual carries it through a hidden form field (`registrations/new.html.erb:17`). First-touch wins — the cookie is only set when blank.

## Flow 1 — Phantom (web3 wallet)

**Entry:** `GET /auth/solana/nonce` → `POST /auth/solana/verify`
**Key files:** `app/views/layouts/application.html.erb` (inline Alpine), `app/javascript/wallet_provider.js`,
`phantom_deeplink.js` (mobile), `solana_sessions_controller.rb`, `concerns/solana/session_auth.rb`,
`solana-studio` gem `auth_verifier.rb`

```mermaid
sequenceDiagram
    autonumber
    actor U as 👤 User
    participant FE as 🖥️ Browser · Alpine<br/>FRONTEND
    participant PH as 👻 Phantom wallet<br/>THIRD PARTY
    participant BE as ⚙️ Rails · SolanaSessionsController<br/>BACKEND
    participant DB as 🗄️ Postgres<br/>DATABASE
    participant CH as ⛓️ Solana chain<br/>ON-CHAIN

    U->>FE: Click Connect Wallet
    FE->>PH: provider.connect()
    PH-->>U: Approve connection?
    U-->>PH: Approve
    PH-->>FE: publicKey (base58)

    FE->>BE: GET /auth/solana/nonce
    BE->>BE: Generate nonce — SecureRandom.hex(16), store in session
    BE-->>FE: { nonce }

    FE->>FE: Build SIWS message<br/>host + pubkey + statement + nonce
    FE->>PH: signMessage(message)
    PH-->>U: Approve signature?
    U-->>PH: Approve
    PH-->>FE: ed25519 signature

    FE->>BE: POST /auth/solana/verify<br/>{ message, signature, pubkey }
    BE->>BE: Solana::AuthVerifier.verify!<br/>ed25519 gem · nonce burn · host bind · 300s TTL
    BE->>DB: User.from_solana_wallet(pubkey) — SELECT
    alt New user
        BE->>DB: INSERT users (web3_solana_address)
        Note over BE,DB: after_create :generate_managed_wallet!
        BE->>BE: Solana::Keypair.generate — local ed25519<br/>encrypt with MANAGED_WALLET_ENCRYPTION_KEY
        BE->>DB: UPDATE users — web2_solana_address +<br/>encrypted_web2_solana_private_key
    end
    BE->>BE: set_app_session — Rails cookie<br/>turf_user_id · session_token · onchain flag
    BE-->>FE: { success, redirect }
    FE->>U: Redirect to /

    Note over CH: ⛓️ Solana chain is never contacted — sign-up is pure ed25519 crypto (OPSEC-044)
```

> **Mobile:** when the Phantom extension is absent, `phantom_deeplink.js` redirects to
> `phantom.app/ul/v1/signIn`; the encrypted response is decrypted client-side in
> `solana_sessions/phantom_callback.html.erb`, which then POSTs the same
> `{ message, signature, pubkey }` to `/auth/solana/verify`.

## Flow 2 — Google (OAuth)

**Entry:** `POST /auth/google_oauth2` (OmniAuth middleware) → `GET /auth/google_oauth2/callback`
**Key files:** `config/initializers/omniauth.rb`, `omniauth_callbacks_controller.rb`,
`app/services/google_oauth_validator.rb`, `registrations/new.html.erb` + `sessions/new.html.erb` (buttons)

```mermaid
sequenceDiagram
    autonumber
    actor U as 👤 User
    participant FE as 🖥️ Browser<br/>FRONTEND
    participant MW as ⚙️ OmniAuth Rack middleware<br/>BACKEND
    participant GO as 🔑 Google OAuth<br/>THIRD PARTY
    participant BE as ⚙️ Rails · OmniauthCallbacksController<br/>BACKEND
    participant DB as 🗄️ Postgres<br/>DATABASE

    U->>FE: Click Sign up with Google
    FE->>MW: POST /auth/google_oauth2  (button_to + CSRF)
    MW-->>FE: 302 redirect to accounts.google.com
    FE->>GO: Authorization request — scope email, profile
    GO-->>U: Google login + consent screen
    U-->>GO: Consent
    GO-->>FE: 302 to /auth/google_oauth2/callback?code=…
    FE->>MW: GET /auth/google_oauth2/callback?code=…
    MW->>GO: Exchange code for tokens (server-side)
    GO-->>MW: id_token + userinfo — email, name, sub
    MW->>BE: omniauth.auth hash to OmniauthCallbacksController#create
    BE->>GO: GoogleOauthValidator — GET oauth2.googleapis.com/tokeninfo
    GO-->>BE: aud · email_verified · exp  (OPSEC-005 re-check)
    BE->>DB: User.from_omniauth — SELECT by provider+uid, then email
    Note over BE,DB: New user — after_create :generate_managed_wallet!
    BE->>DB: INSERT users (provider, uid, email, email_verified_at)
    BE->>BE: Solana::Keypair.generate — local ed25519<br/>encrypt with MANAGED_WALLET_ENCRYPTION_KEY
    BE->>DB: UPDATE users — web2_solana_address +<br/>encrypted_web2_solana_private_key
    BE->>BE: set_app_session — Rails cookie<br/>turf_user_id · session_token
    BE-->>FE: Redirect to / (or popup-close postMessage)
    FE->>U: Logged in — prompted to complete profile (pick a username)

    Note over GO,BE: No Solana RPC · no on-chain write · no email — Google already verified the address
```

> A second surface — the in-contest "Turf Totals" auth modal — opens `/auth/google_popup` in a
> 500×650 popup; on success it `postMessage`s the opener window and closes. Same backend path.

## Flow 3 — Manual (email + password)

**Entry:** `GET /signup` now 301-redirects to the unified `/signin` page (`sessions#new`); the magic-link request is the primary email surface. `POST /signup` (account-from-email) stays as a no-live-UI fallback.
**Key files:** `registrations/new.html.erb` (view override) + `app/controllers/registrations_controller.rb` (**local override** of the engine controller — age-attestation gate when `ENABLE_AGE_ATTESTATION` is on, `tokens_buy_path` redirect), `email_verifications_controller.rb` + `user_mailer.rb` (separate verify flow)

> ⚠️ The diagram below predates the password removal (2026-06-01, PR #18): there are no password
> fields anymore — `POST /signup` creates the account from email alone (`Studio.registration_params`),
> and magic link is the only email *login*. The wallet/session spine in the diagram is still accurate.

```mermaid
sequenceDiagram
    autonumber
    actor U as 👤 User
    participant FE as 🖥️ Browser<br/>FRONTEND
    participant BE as ⚙️ Rails · RegistrationsController<br/>BACKEND (studio-engine gem)
    participant DB as 🗄️ Postgres<br/>DATABASE
    participant RS as 📧 Resend<br/>THIRD PARTY

    U->>FE: GET /signup
    FE-->>U: Registration form — email, password, confirmation
    U->>FE: Fill form + submit
    FE->>BE: POST /signup  { email, password, confirmation }
    BE->>BE: User.new · validations · has_secure_password (bcrypt)
    BE->>DB: INSERT users (email, password_digest)
    Note over BE,DB: after_create :generate_managed_wallet!
    BE->>BE: Solana::Keypair.generate — local ed25519<br/>encrypt with MANAGED_WALLET_ENCRYPTION_KEY
    BE->>DB: UPDATE users — web2_solana_address +<br/>encrypted_web2_solana_private_key
    BE->>BE: set_app_session — Rails cookie<br/>turf_user_id · session_token
    BE-->>FE: Redirect to /tokens/buy — Welcome to Turf Monster
    FE->>U: Logged in immediately — email_verified_at is still NULL

    rect rgb(238, 246, 255)
    Note over U,RS: Separate, later, user-initiated flow — NOT part of sign-up
    U->>BE: POST /email_verification
    BE->>BE: Build signed token — message_verifier, 24h expiry
    BE->>RS: UserMailer.email_verification.deliver_later
    RS-->>U: Verification email — from alex@turfmonster.media (domain verified 2026-05-20)
    U->>BE: GET /email_verification/:token  →  users.email_verified_at = now
    end
```

> Email verification is **not** part of sign-up — manual users are logged in immediately with
> `email_verified_at` NULL. The separate `/email_verification` flow sends a 24h signed token via
> Resend (`turfmonster.media`, a verified sending domain). Google users skip it (born verified).

## What to notice

1. **Three doors, one room.** No shared sign-up controller — the three controllers are entirely
   separate. A 4th sign-up method would inherit the managed wallet + session for free, because
   both live on the `User` model, not in controller code.
2. **On-chain sits sign-up out entirely.** Even the Phantom/web3 flow never calls a Solana RPC
   node. `OPSEC-044` deliberately removed the one on-chain call (`EnsureAtaJob`) to stop sybil
   wallets draining rent SOL. A new wallet is just encrypted bytes in Postgres until its first
   funding / contest entry.
3. **Everyone gets a custodial wallet — even Phantom users.** A Phantom sign-up ends with *both*
   `web3_solana_address` (the user's own wallet) and `web2_solana_address` (server-managed, key
   encrypted at rest). Only admins are exempt — `generate_managed_wallet!` has `return if admin?`.
4. **Email is off the critical path.** Manual sign-up logs you in immediately; `email_verified_at`
   stays NULL until the user opts into the separate `/email_verification` flow. Google users are
   born verified (re-checked server-side, OPSEC-005). No sign-up flow blocks on email delivery.
5. **One model, one cookie.** No `Session`, `Wallet`, `Identity`, or `ManagedWallet` table — all
   of it is columns on `users`, and the session is a plain Rails cookie (`turf_user_id` +
   `session_token`, the latter force-logging-out on mismatch — OPSEC-045).

## Key files

| Area | File | Role |
|---|---|---|
| **Shared** | `app/models/user.rb` | `ensure_username` (L20, L312), `enqueue_onchain_account_setup` (L27, L317), `generate_managed_wallet!` (L237), `set_initial_session_token` (L22, L217), `from_solana_wallet`, `from_omniauth` |
| | `app/models/session_context.rb` | PORO — canonical guest/web2/web3 mode for `$store.session` (2026-05-20) |
| | `app/jobs/create_onchain_user_account_job.rb` | Async on-chain `UserAccount` PDA + username creation at signup (2026-05-22) |
| | `app/services/solana/keypair.rb` | Managed-wallet keypair encryption (`MANAGED_WALLET_ENCRYPTION_KEY`) |
| | `app/services/solana/vault.rb` | `ensure_user_account`, `create_user_account`, `set_username`, `build_set_username` |
| | `app/controllers/application_controller.rb` | `set_app_session`, `verify_session_token`, `wallet_context` (builds `SessionContext`) |
| | `config/initializers/studio.rb` | `session_key = :turf_user_id`, `registration_params` |
| | `db/schema.rb` | `users` — `web2_/web3_solana_address`, `encrypted_web2_solana_private_key`, `session_token`, `username` |
| **Phantom** | `app/views/layouts/application.html.erb` | Inline Alpine `solanaWalletConnect()` — connect, sign, POST |
| | `app/javascript/wallet_provider.js` · `phantom_deeplink.js` | Phantom detection; mobile deep-link |
| | `app/controllers/solana_sessions_controller.rb` | `#nonce`, `#verify`, `#phantom_callback` |
| | `app/controllers/concerns/solana/session_auth.rb` | Nonce replay protection (delete-before-verify) |
| | `solana-studio` gem `lib/solana/auth_verifier.rb` | ed25519 signature verification |
| **Google** | `config/initializers/omniauth.rb` | `omniauth-google-oauth2` provider config |
| | `app/controllers/omniauth_callbacks_controller.rb` | `#create` (find-or-create), `#popup`, `#failure` |
| | `app/services/google_oauth_validator.rb` | Server-side `tokeninfo` re-validation (OPSEC-005) |
| **Manual** | `app/views/registrations/new.html.erb` | Registration form (view override) |
| | `studio-engine` gem `registrations_controller.rb` | `#create` |
| | `app/controllers/email_verifications_controller.rb` · `app/mailers/user_mailer.rb` | Separate email-verification flow |
