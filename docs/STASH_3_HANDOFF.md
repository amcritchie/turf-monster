# `stash@{3}` salvage — handoff

The `signup-transition-refactor` branch carried 3359 lines of
working-tree-only WIP when it was merged to main (via `dcc577a`).
Since the WIP wasn't committed first, the merge brought in only what
was on the branch — not the WIP. The WIP sat in `stash@{3}` until
this salvage cycle.

This doc records what was salvaged into main vs what stayed in the
stash, so a future agent can resume any of the punted work without
re-doing the discovery. The stash itself is **dropped** after this
doc lands (it's recoverable from reflog for ~30 days).

## What landed on main (this salvage cycle)

| PR | Files |
|----|-------|
| #6 — modal-preview gallery restore | `app/controllers/admin_controller.rb` (MODAL_VARIANTS + 3 actions), `app/views/admin/modals.html.erb`, `app/views/admin/modal_preview.html.erb`, `app/views/layouts/modal_preview.html.erb`, 3 routes |
| this PR — salvage finale | 6 modal partials (`_username`, `_crop_photo`, `blocks/_card_header`, `blocks/_close_button`, `studio/modals/_host`, `components/_avatar_cropper`) + 2 audit docs + `view_comment_hygiene_test` + `user_seeds_snapshot` + `test_scaffolding_guard` + USDT asset + re-add 2 MODAL_VARIANTS entries |

## What's punted (not on main, source available in `git reflog` / stash@{3})

### 1. Contest entry service refactor (8 files, depends on `contests_controller` +118 diff)

Polymorphic contest-entry flows extracted from `ContestsController`:

- `app/services/contest_entry_service.rb` (57)
- `app/services/contest_entry/result.rb` (11)
- `app/services/contest_entry/no_op_flow.rb` (15)
- `app/services/contest_entry/offchain_vault_flow.rb` (36)
- `app/services/contest_entry/token_funded_flow.rb` (45)
- `test/services/contest_entry_service_test.rb` (66)
- `test/services/contest_entry/offchain_vault_flow_test.rb` (65)
- `test/services/contest_entry/token_funded_flow_test.rb` (88)
- Requires applying the +118-line `contests_controller.rb` diff to wire
  the services up. Without the controller diff, the services are orphan
  code that the tests cover in isolation but no production path hits.

### 2. Account freeze (B4 / OPSEC-048) (4 files + DIFFERS)

Chargeback / dispute / refund account-freeze feature:

- `db/migrate/20260523200000_add_frozen_at_to_users.rb` (17)
- `test/controllers/account_freeze_test.rb` (64)
- `app/models/user.rb` +40 DIFFERS (adds `frozen?`, `freeze!`, freeze
  scope, `can_change_username?`, `next_entry_number_for(contest)`)
- `app/controllers/accounts_controller.rb` +3 DIFFERS
- Notes: while frozen, the user can't enter contests, buy tokens, or
  withdraw. Existing balance is read-only. See the inline comments on
  `user.rb` `frozen?` / `freeze!`.

### 3. Admin users CRUD (3 files + admin_controller diff)

Admin interface for browsing + freezing users:

- `app/controllers/admin/users_controller.rb` (54)
- `app/views/admin/users/index.html.erb` (111)
- `test/controllers/admin/users_controller_test.rb` (66)
- Requires adding `resources :users, only: [:index, :update]` (or
  similar) inside the `namespace :admin` block in `config/routes.rb`,
  plus the +22-line `admin_controller.rb` DIFFERS (which is just the
  Username + Crop Photo MODAL_VARIANTS entries — already re-added in
  this PR, so the AdminController DIFFERS is now satisfied).

### 4. OAuth POST-only hardening (3 files)

CSRF defense for the OAuth request phase:

- `app/views/omniauth_callbacks/popup.html.erb` (9) — auto-submitting
  POST form for the popup-flow Google login.
- `app/controllers/omniauth_callbacks_controller.rb` +7 DIFFERS —
  changes `popup` action from `redirect_to "/auth/google_oauth2"`
  (GET) to `render layout: false` (renders popup.html.erb).
- `config/initializers/omniauth.rb` +9 DIFFERS — restricts request
  phase to `[:post]` (drops `:get` to close the `<img src>` CSRF
  vector). Requires every OAuth entrypoint (links, JS fallbacks) to
  POST with a CSRF token — verify all callers before flipping.

### 5. Cookie domain scoping (OPSEC-046) (1 file)

- `config/initializers/session_store.rb` +24 DIFFERS — narrows session
  cookie `domain` from `.mcritchie.studio` (shared across all subs) to
  `turf.mcritchie.studio` (this app only). Closes future XSS-on-sibling-
  app exfiltration. **Tradeoff**: disables the studio-engine "Continue
  as X" cross-app SSO button (no shared cookie). Acceptable for a
  mainnet money app per the inline comment.

### 6. Stale DIFFERS files (do not apply blindly)

About 30 files in the stash have non-trivial diffs against current
main but represent OLDER state than what's on main today (the other
session has been actively iterating on these surfaces since the
stash was taken). Applying the stash version of any of these would
be a regression. Notable ones:

- `app/views/accounts/show.html.erb` (494 diff lines)
- `app/views/modals/auth/_tokens.html.erb` (267)
- `app/views/contests/_turf_totals_board.html.erb` (141)
- `app/views/tokens/processing.html.erb` (143)
- `app/views/layouts/application.html.erb` (72)
- `app/views/modals/_auth.html.erb` (94)
- `app/controllers/tokens_controller.rb` (15)
- `app/controllers/webhooks/stripe_controller.rb` (31)

Don't restore these. If specific behavior from one of them is needed,
inspect the diff in isolation and re-implement on top of current main.

## How to resume any of the punted features

```bash
# Get back to the source content
git fsck --no-reflog --lost-found  # find dropped stash if reflog expired
# or just within ~30 days:
git stash show -u stash@{3}        # full stat
git show 'stash@{3}^3:<path>'      # untracked file content
git show 'stash@{3}:<path>'        # tracked-modification content
```

Each feature above is self-contained enough to resurrect as a
focused PR. Start with the file list, restore + adapt to current
main, write tests if any are missing.
