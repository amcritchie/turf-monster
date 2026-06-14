# Email delivery — transport + the Resend → SES cutover

Turf Monster sends transactional email (magic-link sign-in, verification, wallet
export, email-change, contest winnings, newsletter welcome) through ActionMailer.
Every send is also recorded as an `EmailDelivery` audit row (`sent` boolean).

## Transport switch

The active transport is chosen by **`MAIL_TRANSPORT`** (`resend` | `ses`,
default `resend`). Turf uses the shared Studio engine mail transport:

| `MAIL_TRANSPORT` | Active transport | Notes |
|---|---|---|
| unset / `resend` | **Resend** (`:resend`) | requires `RESEND_API_KEY`. Default + revert target. |
| `ses` (+ SES creds) | **SES** (`:smtp`) | requires `SES_SMTP_USERNAME` / `SES_SMTP_PASSWORD` / `SES_REGION`. |
| `ses` (creds missing) | **Resend** (fallback) | logs a warning; never silently breaks mail. |

- `config/initializers/studio_mail_transport.rb` — calls `Studio::MailTransport.configure!`.
- `studio-engine` owns `Studio::MailTransport`, the Resend dependency, and the shared `ses:*` Rake tasks.
- `MAILER_FROM` sets both `Studio.mailer_from` and the app mailer default, so engine magic links and app transactional mail use one sender.
- Tests always use `:test` (in-memory); the transport no-ops in `Rails.env.test?`.

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

Turf Monster is bundled with `studio-engine 0.5.2+`, so the compatibility
fallback has been removed from the app. Keep future transport changes in
`studio-engine` unless they are truly app-specific.
