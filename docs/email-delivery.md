# Email delivery — transport + the Resend → SES cutover

Turf Monster sends transactional email (magic-link sign-in, verification, wallet
export, email-change, contest winnings, newsletter welcome) through ActionMailer.
App code calls `Studio::Email.deliver`; the shared facade delegates to Turf's
existing top-level `EmailDelivery` outbox, so every send is recorded as an audit
row (`sent` boolean).

## Transport switch

The active transport is chosen by **`MAIL_TRANSPORT`** (`resend` | `ses`,
default `resend`). Turf uses the shared Studio engine mail transport:

| `MAIL_TRANSPORT` | Active transport | Notes |
|---|---|---|
| unset / `resend` | **Resend** (`:resend`) | requires `RESEND_API_KEY`. Default + revert target. |
| `ses` (+ SES creds) | **SES** (`:smtp`) | requires `SES_SMTP_USERNAME` / `SES_SMTP_PASSWORD` / `SES_REGION`. |
| `ses` (creds missing) | **Resend** (fallback) | logs a warning; never silently breaks mail. |

- `config/initializers/studio_mail_transport.rb` — calls `Studio::MailTransport.configure!`.
- `studio-engine` owns `Studio::MailTransport`, `Studio::Email.deliver`, the
  Resend dependency, and the shared `ses:*` Rake tasks.
- `MAILER_FROM` sets both `Studio.mailer_from` and the app mailer default, so engine magic links and app transactional mail use one sender.
- Tests always use `:test` (in-memory); the transport no-ops in `Rails.env.test?`.

## Local agent inbox

In non-production, `studio-engine` exposes a local inbox:

```text
http://localhost:3100/_studio/local_emails
```

Worktree stacks launched through McRitchie Studio's `bin/agent-worktree` set
`LOCAL_EMAIL_CAPTURE=1` and blank provider mail credentials in `.env.agent-stack`.
In that mode `Studio::Email.deliver` still records Turf's `email_deliveries`
rows, but `EmailDeliveryJob` is not enqueued and `deliver_now!` refuses to send.
Agents should use the inbox URL as the proof surface for magic-link/auth work
instead of asking the user to check Gmail.

Primary local stacks can opt into the same behavior with `LOCAL_EMAIL_CAPTURE=1`.
Set `LOCAL_EMAIL_CAPTURE=0` only when the task is explicitly testing SES/Resend
provider delivery.

## Durable delivery

Turf Monster keeps its existing `email_deliveries` table and `EmailDeliveryJob`.
The shared `Studio::Email.deliver` facade uses that app-level adapter first, so
Turf can align call sites with McRitchie Studio without moving production data
into `studio_email_deliveries` yet.

Use `EmailDelivery.resend_unsent!` after a provider or worker outage.

## Goal: fully off Resend.com → SES

SES is pay-per-use ($0.10/1k, no monthly fee) and supports both sending domains.
The cutover is a one-variable flip once the prerequisites below are met.

### Prerequisites (ops — AWS / DNS / Heroku)
1. **SES production access** — out of sandbox for the region (sandbox only sends to verified addresses).
2. **`turfmonster.media` verified** in SES with DKIM (3 CNAMEs on name.com). `bin/rails "ses:verify_domain[turfmonster.media]"` prints the records.
3. **SPF + DMARC** for turfmonster.media (SPF `include:amazonses.com`).
4. **SES SMTP creds** on Heroku: `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, `SES_REGION`.

Verify state any time: `bin/rails ses:check` (needs `AWS_ACCESS_KEY_ID/SECRET` + `SES_REGION` in env).

### Cutover
```sh
heroku config:set -a turf-monster-mainnet \
  SES_SMTP_USERNAME=… SES_SMTP_PASSWORD=… SES_REGION=us-east-2   # stage (inert)
heroku config:set -a turf-monster-mainnet MAIL_TRANSPORT=ses     # the flip
# smoke test: send a magic link in prod, confirm delivery + DKIM pass
```

### Revert (instant)
```sh
heroku config:unset -a turf-monster-mainnet MAIL_TRANSPORT       # Resend resumes
```

### Decommission (later, after confidence)
Cancel the Resend subscription + drop `RESEND_API_KEY` only after SES has been
stable long enough that the rollback path is no longer useful.

## Engine ownership

Turf Monster is bundled with `studio-engine 0.5.5+`. Keep future shared
transport, delivery facade, and local agent inbox changes in `studio-engine`;
keep Turf-specific catalog entries, previews, and email copy in the app.
