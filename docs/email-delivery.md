# Email Delivery - SES Primary, Resend Rollback

Turf Monster sends transactional email through ActionMailer: magic-link sign-in,
verification, wallet export, email-change, contest winnings, and newsletter
welcome. App code calls `Studio::Email.deliver`; the shared facade delegates to
Turf's existing top-level `EmailDelivery` outbox, so every send is recorded as
an audit row.

Cross-app sender inventory, SES cutover rules, local inbox proof, and rollback
policy live in `mcritchie-studio/docs/agents/modules/email-operations.md`. Keep
this file focused on Turf-specific wiring.

## Transport Switch

The active transport is chosen by `MAIL_TRANSPORT` (`ses` | `resend`). `ses` is
the target state; Resend remains a rollback path while SES adoption is proved.
Turf uses the shared Studio engine mail transport:

| `MAIL_TRANSPORT` | Active transport | Notes |
|---|---|---|
| `ses` with SES creds | SES SMTP | Target state. Requires `SES_SMTP_USERNAME`, `SES_SMTP_PASSWORD`, `SES_REGION`. |
| `ses` without SES creds | Resend fallback | Logs a warning; avoids silently breaking login during setup. |
| unset / `resend` | Resend | Rollback path while the Resend account remains available. |

- `config/initializers/studio_mail_transport.rb` calls `Studio::MailTransport.configure!`.
- `studio-engine` owns `Studio::MailTransport`, `Studio::Email.deliver`, the
  Resend dependency, and the shared `ses:*` Rake tasks.
- `MAILER_FROM` and `MARKETING_MAILER_FROM` are the app-branded SES senders.
- `RESEND_MAILER_FROM` is the shared fallback sender. While SES is blocked by
  sandbox/presetup, Resend sends from `McRitchie Studio
  <team@mcritchie.studio>` instead of requiring another paid Resend domain.
- SES transactional/auth/security/contest email uses `Turf Monster <team@turfmonster.media>`.
- SES newsletter/marketing email uses `Alex from Turf Monster <alex@turfmonster.media>`.
- Tests always use `:test` in memory; the transport no-ops in `Rails.env.test?`.

SES account/domain checks should use `SES_AWS_ACCESS_KEY_ID` and
`SES_AWS_SECRET_ACCESS_KEY` from `agent.aws.mcritchie-ses`. Do not overwrite
Turf's existing S3 or app-level `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
unless that IAM user is deliberately being rotated.

## Local Agent Inbox

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

## Durable Delivery

Turf Monster keeps its existing `email_deliveries` table and `EmailDeliveryJob`.
The shared `Studio::Email.deliver` facade uses that app-level adapter first, so
Turf can align call sites with McRitchie Studio without moving production data
into `studio_email_deliveries` yet.

Use `EmailDelivery.resend_unsent!` after a provider or worker outage.

## Cutover Checklist

Use the shared checklist in
`mcritchie-studio/docs/agents/modules/email-operations.md` first, then apply the
Turf-specific values below.

Current production status, last checked 2026-06-14:

- SES account in `us-east-2`: sending enabled, enforcement healthy, still in
  sandbox (`ProductionAccessEnabled=false`).
- `turfmonster.media`: verified for sending, DKIM `SUCCESS`.
- Persistent production transport: keep Resend active until SES production
  access is approved.
- Production app adoption: deploy the current `studio-engine` release before
  proving the shared `Studio::Email.deliver` provider path on Heroku.

### Prerequisites

1. SES production access is approved in `us-east-2`; sandbox mode can send only
   to verified recipients.
2. `turfmonster.media` is verified in SES with DKIM. Run
   `bin/rails "ses:verify_domain[turfmonster.media]"` to print the records.
3. SPF includes Amazon SES, and DMARC exists for `turfmonster.media`.
4. SES SMTP creds are staged on Heroku: `SES_SMTP_USERNAME`,
   `SES_SMTP_PASSWORD`, `SES_REGION`.
5. `MAILER_FROM="Turf Monster <team@turfmonster.media>"` is set.
6. `MARKETING_MAILER_FROM="Alex from Turf Monster <alex@turfmonster.media>"` is set for newsletter/marketing mail.
7. `RESEND_MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"` is set for rollback/presetup mail.

Verify state any time:

```bash
bin/rails ses:check
```

### Cutover

```bash
heroku config:set -a turf-monster-mainnet \
  SES_SMTP_USERNAME=... SES_SMTP_PASSWORD=... SES_REGION=us-east-2
heroku config:set -a turf-monster-mainnet \
  MAILER_FROM="Turf Monster <team@turfmonster.media>" \
  MARKETING_MAILER_FROM="Alex from Turf Monster <alex@turfmonster.media>" \
  RESEND_MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"
heroku config:set -a turf-monster-mainnet MAIL_TRANSPORT=ses
```

Smoke test a production magic link and confirm delivery plus DKIM/SPF/DMARC pass.

### Rollback

```bash
heroku config:unset -a turf-monster-mainnet MAIL_TRANSPORT
```

Resend resumes if `RESEND_API_KEY` is present.

### Decommission

Follow the shared decommission criteria before canceling Resend or dropping
`RESEND_API_KEY`.

## Engine Ownership

Turf Monster is bundled with `studio-engine 0.5.6+`. Keep future shared
transport, delivery facade, and local agent inbox changes in `studio-engine`;
keep Turf-specific catalog entries, previews, and email copy in the app.
