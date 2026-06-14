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
- `MAILER_FROM` sets both `Studio.mailer_from` and the app mailer default, so
  engine magic links and app transactional mail use one sender.
- Tests always use `:test` in memory; the transport no-ops in `Rails.env.test?`.

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

### Prerequisites

1. SES production access is approved in `us-east-2`; sandbox mode can send only
   to verified recipients.
2. `turfmonster.media` is verified in SES with DKIM. Run
   `bin/rails "ses:verify_domain[turfmonster.media]"` to print the records.
3. SPF includes Amazon SES, and DMARC exists for `turfmonster.media`.
4. SES SMTP creds are staged on Heroku: `SES_SMTP_USERNAME`,
   `SES_SMTP_PASSWORD`, `SES_REGION`.
5. `MAILER_FROM=noreply@turfmonster.media` is set.

Verify state any time:

```bash
bin/rails ses:check
```

### Cutover

```bash
heroku config:set -a turf-monster-mainnet \
  SES_SMTP_USERNAME=... SES_SMTP_PASSWORD=... SES_REGION=us-east-2
heroku config:set -a turf-monster-mainnet MAILER_FROM=noreply@turfmonster.media
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
