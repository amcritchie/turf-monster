# Local Stack

Use this when an agent or background session needs to run Turf Monster locally and hand back an inspectable URL.

## Primary Stack

Primary local URL:

```text
http://localhost:3100
```

Start or adopt the full local stack:

```bash
bin/tm up
```

`bin/tm` manages:

- Rails web on `3100`.
- Sidekiq on `default` and `mailers`.
- Stripe listener forwarding to `localhost:3100/webhooks/stripe` when the Stripe CLI and `.env` key are available.
- Redis and Postgres preflights.
- One-shot Tailwind build.
- Readiness polling before reporting the URL.
- Stripe webhook signing-secret mismatch checks.

Useful commands:

```bash
bin/tm status
bin/tm logs web
bin/tm logs sidekiq
bin/tm logs stripe
bin/tm restart
bin/tm down
```

Use `bin/tm restart` after changing `.env`, gems, migrations, or anything Sidekiq reads at boot.

## Human Interactive Stack

`bin/dev` is for an interactive terminal where combined logs are useful. It does not start the Stripe listener and can self-terminate in background/no-TTY agent sessions because the Tailwind watcher exits.

Agents should prefer `bin/tm up`.

## Callback Rule

Keep callback-heavy flows on the primary stack unless the external provider is configured for a worktree port.

Primary `3100` is used by:

- Stripe webhook forwarding.
- Google OAuth redirects.
- MoonPay/CDP callbacks.
- Webhooks.
- Emailed magic links.

Worktree stacks should use `3101+` and separate Redis DBs.

Prefer McRitchie Studio's central launcher for named parallel stacks:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-worktree new turf-monster task-slug
bin/agent-worktree up turf-monster task-slug
```

This creates the worktree under `turf-monster/.worktrees/`, assigns the port, database, Redis DB, and session cookie key, then prints the review URL.

## Required Local Secrets

At minimum, `.env` needs:

- `RAILS_MASTER_KEY`
- `SECRET_KEY_BASE`
- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `SOLANA_ADMIN_KEY`
- `SOLANA_RPC_URL`
- `MANAGED_WALLET_ENCRYPTION_KEY`

Use McRitchie Studio's agent credential docs for current 1Password item names. Do not print secret values in terminal output or handoff notes.
