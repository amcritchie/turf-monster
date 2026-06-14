# Workflow: Web3 — landing page to on-chain contest entry

> **Code is law.** Every claim below cites `path/to/file.rb:NN` from the current
> codebase. Re-confirm on edit — line numbers drift on refactor.

**Trigger:** `GET /l/:slug` (a marketing funnel page) — typically reached from a
paid ad, an X/Twitter post, or a friend's share link with `?reference=…`.
**Actors:** Guest visitor → User (created mid-flow) · Phantom wallet · Rails ·
Sidekiq · Solana devnet/mainnet RPC.
**Outcome:** New `User` row with `web3_solana_address` set, a server-managed
wallet (`web2_solana_address`) attached, an on-chain `UserAccount` PDA
created with username, and an `active` `Entry` row whose `onchain_tx_signature`
points at the `enter_contest` instruction confirmed on-chain.
**Preconditions:** A `LandingPage` row is `active: true` with a `contest_id`
wired (`app/models/landing_page.rb:46`), and that `Contest` is `open` and
`onchain?` (i.e. its `onchain_contest_id` is set). Phantom must be installed in
the browser or available via mobile deep link.

## Sequence

1. **Land on funnel.** `GET /l/:slug` → `LandingPagesController#show` —
   `app/controllers/landing_pages_controller.rb:7`.
   - Auth skipped (`:require_authentication` and `:require_profile_completion`
     in lines 2–3) — funnels are public.
   - Inactive pages 404-ish (`redirect_to root_path` with alert) unless the
     viewer is admin previewing (`:11`).
   - First-touch attribution: writes `cookies[:reference] = @landing_page.slug`
     with 30-day expiry if not already set (`:18`). An explicit `?reference=…`
     captured earlier by `ApplicationController#capture_reference`
     (`app/controllers/application_controller.rb:51`) wins because that
     handler runs before this one.
   - Hero CTA renders `link_to @landing_page.cta_label_display,
     contest_path(@contest.slug, scroll: 280)` with `target: "_blank"`
     (`app/views/landing_pages/show.html.erb:64`). The `scroll=280` URL param
     auto-scrolls the contest page past hero chrome to the matchup board
     (`app/views/contests/show.html.erb:252`).
   - Route: `get "l/:slug", to: "landing_pages#show", as: :landing_page` —
     `config/routes.rb:75`.

2. **Land on contest.** New tab opens `GET /contests/:slug?scroll=280` →
   `ContestsController#show` — `app/controllers/contests_controller.rb:222`.
   - `:show` is in the auth-skip list (`:4`), so guests render.
   - `@contest = Contest.find_by(slug: params[:id])` via
     `set_contest` (`:927`). On miss, a forensic warning logs slug / referer /
     turbo-frame for the recurring "Contest not found" toast (`:935-946`).
   - Hero, stats row, and inline matchup board render iff the contest is
     `open?` and the viewer hasn't entered yet
     (`app/views/contests/show.html.erb:118-122`).
   - The board partial mounts `x-data="selectionBoard()"` —
     `app/views/contests/_turf_totals_board.html.erb:1185`. The factory is
     defined inline (`:61-1182`) because Alpine processes `x-data` before
     importmap modules load (see `docs/UI_PATTERNS.md` § Alpine + ERB Constraints).
   - Board config — picks_required, matchup data, contest slug, cart state — is
     serialized into `<script id="board-config">…</script>` JSON
     (`:25-56`). Auth state is read live from `Alpine.store('session')` (the
     canonical web2/web3/guest pivot), never copied into the config (`:39-41`).

3. **Build cart (no auth required).** Guest taps matchup cards. Each tap calls
   `selectionBoard.toggleSelection(matchupId)` — `_turf_totals_board.html.erb:307`.
   - If the user is a guest (`!this.loggedIn` at `:340`), the click only
     mutates local Alpine state — no network round-trip.
   - When logged in, `POST /contests/:id/toggle_selection` →
     `ContestsController#toggle_selection`
     (`app/controllers/contests_controller.rb:652`) creates an `Entry` with
     `status: :cart` (`:660`) and toggles a `Selection` via
     `Entry#toggle_selection!` (`app/models/entry.rb:29`). Hard-capped at
     `contest.picks_required` (= 6 for Turf Totals) — extras replace the oldest.
   - At 6 selections the UI blurs the page and the "Hold to Confirm" button
     appears (`_turf_totals_board.html.erb:1194-1200`, `:1368-1382`).

4. **Hold-to-Confirm fires.** Shared hold-button partial dispatches the
   `hold-confirm-entry` window event on success
   (`_turf_totals_board.html.erb:1378`); the board's `init()` listener
   (`:174-182`) routes it into `selectionBoard.confirmEntry()` (`:899`).
   - `runHoldValidations()` at `:878` first hits `GET /geo/check`
     (`config/routes.rb:287`); a blocked state aborts with the
     `Location Restricted` redirect modal (`:884`).
   - If `!this.loggedIn` (read live from `Alpine.store('session')`),
     `confirmEntry()` short-circuits to `showLoginModal()` (`:899-904`).
     `Alpine.store('session').isGuest` is the canonical guest pivot — derived
     from `SessionContext#mode` (`app/models/session_context.rb:29`),
     hydrated from `<script id="session-context">` on every render
     (`app/views/layouts/application.html.erb:62, 175-180`).

5. **Sign up via Phantom.** Auth wizard opens at `step: 'credentials'`
   (`_turf_totals_board.html.erb:390-402`). Clicking the Phantom button
   dispatches `auth-phantom-click`, handled by `loginWithPhantom()` at
   `:536`.
   - `provider.connect()` opens Phantom; the SIWS message is built locally
     (`:562`) — `domain + pubkey + 'User-ID:' + sessUid + 'Nonce:'` —
     where the nonce comes from `GET /auth/solana/nonce`
     (`app/controllers/solana_sessions_controller.rb:5-9`). User-ID is OPSEC-005
     wallet-hijack defense.
   - `provider.signMessage(...)` returns an ed25519 signature; encoded base58
     and `POST`ed to `/auth/solana/verify` (`:567`).

6. **Server verifies + creates User.** `SolanaSessionsController#verify` —
   `app/controllers/solana_sessions_controller.rb:25`.
   - `verify_solana_signature!` (from
     `app/controllers/concerns/solana/session_auth.rb:20`) runs pure-Ruby
     ed25519 via `Solana::AuthVerifier.verify!` (in the `solana-studio` gem) —
     nonce delete-before-verify, host bind, 300s TTL. **No Solana RPC call**
     during signup (OPSEC-044 — see `docs/SIGNUP_FLOWS.md`).
   - `User.from_solana_wallet(pubkey_b58)` looks up an existing user
     (`app/models/user.rb:87`); if absent, a new `User` is built with
     `web3_solana_address: pubkey_b58` and `reference: cookies[:reference]` — first-touch funnel attribution
     pulled off the cookie set by the landing page in step 1
     (`solana_sessions_controller.rb:37-42`).
   - `user.save!` triggers the shared spine:
     - `before_validation :ensure_username` — auto-fills a username via
       `Studio::UsernameGenerator.generate` (`app/models/user.rb:20`, `:312`).
     - `before_create :set_initial_session_token` — writes
       `users.session_token` (`:22`, `:217`) for OPSEC-045 cookie binding.
     - `after_create :generate_managed_wallet!` (`:23`, `:237`) generates a
       server-managed ed25519 keypair via `Solana::Keypair.generate`
       (local, no RPC), encrypts the secret key with
       `MANAGED_WALLET_ENCRYPTION_KEY`, and writes `web2_solana_address` +
       `encrypted_web2_solana_private_key`. **Admins are excluded** (`:244`).
     - `after_commit :enqueue_onchain_account_setup` (`:27`, `:317`) →
       `CreateOnchainUserAccountJob.perform_later(id)`. Async — the user is
       logged in before the on-chain PDA finalizes.
   - `cookies.delete(:reference)` consumes the cookie iff this was a new
     signup (`solana_sessions_controller.rb:46`).
   - `set_app_session(user)` writes `session[:turf_user_id]` +
     `session[:session_token]` (`app/controllers/application_controller.rb:19`),
     then `session[:onchain] = true` flips the wallet-signature flag that
     `onchain_session?` reads (`solana_sessions_controller.rb:48`,
     `application_controller.rb:78`).
   - Response: `render json: { success: true, redirect: tokens_buy_path,
     new_user: true }` for new signups (`:52`). **But** the in-board Phantom
     flow ignores that redirect — `loginWithPhantom()` calls
     `this.saveCartForRedirect(true)` and `window.location.reload()`
     (`_turf_totals_board.html.erb:583-584`), so the user lands back on the
     contest page with their cart selections persisted server-side and
     `cartOpen: true` restored client-side via `init()`'s
     `pendingContestEntry` replay (`:204-226`).

7. **Background: on-chain UserAccount PDA created.**
   `CreateOnchainUserAccountJob#perform` —
   `app/jobs/create_onchain_user_account_job.rb:10`.
   - Calls `Solana::Vault.new.ensure_user_account(user.solana_address,
     username: user.username)` (`app/services/solana/vault.rb:383`). Idempotent
     no-op if the PDA already exists, so Sidekiq retries are safe (`:14`).
   - This is the FIRST on-chain TX in the whole flow — signup itself is pure
     ed25519. The job runs out-of-band; entry submission below does NOT block
     on it (the entry path re-asserts `ensure_user_account` synchronously,
     see step 9).

8. **Post-reload: cart hydrates + auto-enter fires.** Board `init()` reads
   `sessionStorage.pendingContestEntry`
   (`_turf_totals_board.html.erb:204-226`).
   - Hydrates `selections` + `selectionOrder` (`:213-215`).
   - If `this.loggedIn && pending.autoEnter && selectionCount === picksRequired`,
     `setTimeout(() => self.afterLoginSuccess(), 50)` (`:218-221`).
   - `afterLoginSuccess()` (`:806`) replays selections to the server via
     `replaySelectionsToServer()` (`:666` → repeatedly POSTs `toggle_selection`),
     then calls `confirmEntry()`.

9. **Web3 entry: prepare + sign + confirm.** `confirmEntry()` branches on
   `Alpine.store('session').isWeb3 && this.contestOnchain`
   (`_turf_totals_board.html.erb:908`).
   - **`POST /contests/:id/prepare_entry`** →
     `ContestsController#prepare_entry`
     (`app/controllers/contests_controller.rb:398`).
     - Requires `onchain_session?` — if the cookie says web2 (no live Phantom
       sig this session), returns 403 (`:412`).
     - Hard-fails `contest.world_cup_survivor?` paths cleanly (`:401`).
     - Server validates: contest is on-chain (`:415`), Phantom wallet present
       (`:416`), capacity OK (`:418-419`), exactly `picks_required` selections
       (`:422`), no locked games (`:423-425`), and assigns `entry_number`
       (`:428-429`).
     - `Solana::Vault#ensure_user_account` runs synchronously here
       (`:434`) — closes the race where the async
       `CreateOnchainUserAccountJob` hasn't landed yet.
     - `vault.build_enter_contest(wallet, slug, entry_number,
       season_id: contest.season_id)`
       (`app/services/solana/vault.rb:747`) returns a partially-signed
       transaction (admin pays SOL rent, user co-signs the USDC transfer +
       entry write).
     - Persists a `PendingTransaction` row with `tx_type:
       "enter_contest"`, `status: "pending"`, `target: entry`,
       `metadata: { entry_pda, contest_slug }` (`:452-459`). Survives a
       mid-flight refresh — see failure modes below.
     - Returns `{ success, serialized_tx, entry_id, entry_pda, ptx_slug }`
       (`:461-467`).
   - **Phantom signs.** Client decodes the base64 tx and calls
     `provider.signTransaction(tx)` (`_turf_totals_board.html.erb:946-948`),
     then `connection.sendRawTransaction(...)` against
     `document.body.dataset.solanaRpcUrl` (`:951-952`).
   - **`POST /contests/:id/stamp_entry_signature`** (fire-and-forget) →
     `ContestsController#stamp_entry_signature` (`:479`). Stamps the on-chain
     signature onto the PendingTransaction so a refresh during
     `confirmTransaction` still has a server-side trail (`:486`).
   - **`connection.confirmTransaction(txSig, 'confirmed')`** waits for finality
     (`_turf_totals_board.html.erb:971`).
   - **`POST /contests/:id/confirm_onchain_entry`** →
     `ContestsController#confirm_onchain_entry` (`:568`).
     - `set_contest` finds the entry, asserts user + cart status (`:569`).
     - **OPSEC-010 server-side proof.** Re-derives the entry PDA via
       `Solana::Vault#entry_pda(slug, wallet, entry_number)` (`:579-581`)
       and refuses any client-supplied PDA mismatch (`:582`). Then
       `verify_solana_transaction!` calls `Solana::TxVerifier.verify!`
       (`:584-589`, `:915-924`) to fetch the tx from chain and assert the
       instruction discriminator is `enter_contest`, signed by
       `current_user.web3_solana_address`, writing to the derived PDA.
     - `entry.confirm_onchain!(tx_signature:, entry_pda:)` —
       `app/models/entry.rb:130`. Inside a `user.with_lock` transaction:
       per-user entry limit, sybil-combo check, then `update!(status:
       :active, onchain_tx_signature:, onchain_entry_id:)` (`:158-162`).
       Lock-time enforced server-side (`:135-137`) so a stale Phantom prompt
       can't squeak through after contest lock.
     - Marks the PendingTransaction `confirmed` (`:600-604`).
     - Reads `Solana::Vault#seeds_for_entry(entry_number)` to mirror the
       on-chain `Season.seed_schedule` award (`:608`) and pulls fresh
       `seeds_total` via `sync_balance` (`:611-617`).
   - Modal closes; navbar seeds bar animates; `lobbyUrl = data.redirect ||
     '/contests/{slug}'` countdown redirects to the contest show page
     (`_turf_totals_board.html.erb:1022-1025`).

## Data touched

- `landing_pages` (read in step 1)
- `cookies[:reference]` (write in step 1 — funnel-attribution stamp)
- `contests` (read in steps 2, 5–9; row locked via `@contest.with_lock` in
  `#enter`, not `#prepare_entry`/`#confirm_onchain_entry`)
- `entries` (insert `:cart` in step 3; update to `:active` in step 9 via
  `Entry#confirm_onchain!`)
- `selections` (insert/destroy in step 3)
- `users` (insert in step 6; `web2_solana_address`,
  `encrypted_web2_solana_private_key`, `session_token`, `username`,
  `reference` all populated)
- `pending_transactions` (insert in step 9 `#prepare_entry`; update to
  `submitted` → `confirmed` across steps)
- `session[:turf_user_id]`, `session[:session_token]`, `session[:onchain] =
  true` (write in step 6)
- on-chain: `UserAccount` PDA (`create_user_account` / `ensure_user_account`
  in step 7; re-asserted synchronously in step 9 `#prepare_entry`)
- on-chain: `Entry` PDA + `Contest.entry_fees` USDC credit, seeds award
  per `Season.seed_schedule` — single atomic `enter_contest`
  instruction (step 9)
- external: Solana devnet/mainnet RPC for tx broadcast + confirm + signature
  fetch (logged through `Solana::ClientLogger` →
  `outbound_requests`)
- external: Phantom wallet for two interactions — `signMessage` at signup
  (step 5) and `signTransaction` at entry (step 9). There is no separate
  per-entry SIWS `signMessage` prompt.

## Failure modes

- **`?reference=` cookie collision.** A user who clicks Landing Page A and
  then Landing Page B retains A's attribution — `capture_reference` (and
  `LandingPagesController#show:18`) only sets the cookie when it's blank.
  Symptom: `User.reference` doesn't match the page that converted them.
- **No on-chain Contest PDA.** Paid contests refuse free entry —
  `ContestsController#enter:304-306` raises `"This contest isn't on-chain
  yet — paid entry is unavailable."` Same gate at `Entry#confirm!:97-99`.
  Always set the contest on-chain before publishing the landing page.
- **No active season.** `#enter:296-298` raises `"No active season
  configured."` — operator must visit `/admin/seasons` and call
  `SeasonConfig.set_current!(season_id)` before the on-chain entry path
  works. Caught early so users don't waste a Phantom signature.
- **Wrong wallet connected.** `confirmEntry` re-asserts `pubkeyB58 ===
  sess.address` (`_turf_totals_board.html.erb:923`) before the prepare
  call — symptom: "Wrong wallet connected. Switch to abcd…" toast. User
  must reconnect the wallet that owns the account (Account page) or
  switch Phantom's active wallet.
- **Refresh mid-flight (signed, broadcast, awaiting confirm).** Covered
  by `PendingTransaction` (step 9). On next page load `find_pending_recovery_ptx`
  (`contests_controller.rb:991`) populates `pendingRecoveryPtxSlug` into
  the board config; `init()` calls `recoverPendingEntry()`
  (`_turf_totals_board.html.erb:234-236, 239`) which POSTs
  `/recover_pending_entry` (`contests_controller.rb:502`) — auto-promotes
  to `active` if the tx landed, marks `failed` if it errored, polls every
  5s for ~30s if still propagating.
- **Refresh between sign and broadcast.** `stamp_entry_signature` never
  ran, so `ptx.tx_signature.blank?` (`contests_controller.rb:524`) →
  `ptx.update!(status: "failed")` and toast: `"Your last signature did
  not broadcast — try again."` User retries the hold.
- **OPSEC-010 PDA mismatch.** `confirm_onchain_entry:582` raises `"Entry
  PDA mismatch"` if the client-supplied `entry_pda` differs from the
  server-derived one. Surfaces as red Solana modal; entry stays in
  `:cart`, user can retry.
- **Sybil duplicate-combo entry.** `Entry#confirm_onchain!:153-156`
  raises `"You already have an entry with this exact selection
  combination"`. User must change at least one pick.
- **Per-user entry limit.** `Contest#max_entries_per_user` (3 for Turf
  Totals) enforced inside `user.with_lock` at `:149`.
- **Lock window crossed during signing.** `Entry#confirm_onchain!:135-137`
  raises `"Contest has locked — entries closed"` after `contest.locks_at`.
  Prelaunch audit H7 fix — closes the staggered-kickoff info-edge attack.
- **CreateOnchainUserAccountJob failure.** Logs `[username] ...failed
  user=#{id}` and `raise`s for Sidekiq retry
  (`create_onchain_user_account_job.rb:17-18`). The entry path's
  synchronous `ensure_user_account` (`contests_controller.rb:434`)
  handles the case where the job hasn't yet succeeded by signup time.

## Related workflows

- [[admin-contest-setup]] — predecessor: an operator must publish the
  on-chain Contest PDA + active LandingPage before this flow can run.
- [[email-signup-token-to-chat]] — alternate signup lane (web2 / managed
  wallet) starting from the same landing page; diverges at step 5 into
  Stripe token purchase rather than Phantom signing.
- [[referral-google-tokens-to-chat]] — alternate signup lane (Google
  OAuth) sharing the same `cookies[:reference]` first-touch attribution
  set in step 1.
