# Security Review Checklist

Use this for Turf Monster security or readiness reviews. Historical audit prompts
and old launch reports are context only; start from current docs and code.

## Start Here

Read these before older audits:

- `/Users/alex/projects/AGENTS.md`
- `turf-monster/README.md`
- `turf-monster/docs/AUTH.md`
- `turf-monster/docs/SOLANA.md`
- `turf-monster/docs/LOCAL_STACK.md`
- `turf-monster/docs/TEST_COVERAGE_STATUS.md`
- `turf-vault/docs/CURRENT_DEPLOYMENT.md`
- `turf-vault/docs/VERIFICATION_MATRIX.md`

## Review Surfaces

| Surface | What to verify |
|---------|----------------|
| Auth and account changes | Magic-link consumption, Google OAuth, wallet auth, re-auth for sensitive changes, session-token rotation, email-change behavior. |
| Payment callbacks | Signature verification, provider re-fetch, idempotency keys, duplicate webhook behavior, chargeback/refund freeze paths. |
| Contest entry | Eligibility checks, lock/conclusion gates, double-submit behavior, pending transaction recovery, transaction signature verification. |
| Solana client layer | Program ID liveness, IDL pinning, PDA derivation, signer requirements, stale RPC and schema-drift handling. |
| Admin/operator paths | Admin authorization, CSRF on mutating actions, dry-run versus broadcast clarity, 1-of-3 versus 2-of-3 authority boundaries. |
| Realtime/UI | ActionCable stream exposure, pre-lock pick secrecy, modal state races, stale balance/cache handling. |
| Secrets and observability | Private key redaction, wallet export hardening, session replay exclusions, parameter filtering, ErrorLog payload safety. |
| Deploy gates | `bin/deploy`, `bin/rails solana:health`, IDL re-pin, Heroku env alignment, provider-side blockers. |

## Deliverable

Produce a ranked finding list with:

- severity: critical, high, medium, low, info;
- status: confirmed, uncertain, refuted;
- file references;
- exploit or failure scenario;
- recommended fix;
- verification to run after the fix.

Patch critical/high findings only when the user has approved execution. Do not
deploy, rotate keys, modify `EXPECTED_IDL_HASH`, or touch Squads/upgrade
authority without explicit approval.

## Current Notes

- MoonPay is not active launch infrastructure. Keep MoonPay-specific historical
  findings in context unless that provider returns.
- SES production access is intentionally deferred until audit cleanup is closed.
- Live TurfVault identity comes from `turf-vault/docs/CURRENT_DEPLOYMENT.md`,
  not old launch or rehearsal docs.
