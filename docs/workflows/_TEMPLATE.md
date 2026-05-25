# Workflow: <name>

> **Code is law.** Every claim below must cite `path/to/file.rb:NN` from the current
> codebase. When porting from another MD, verify against the code first — line numbers
> drift, prose rots. When code moves, this file moves with it: re-confirm citations on edit.

**Trigger:** <what kicks it off — route, button click, background job, cron, webhook, manual rake task>
**Actors:** <User / Operator / Sidekiq / Stripe / Resend / Solana RPC / Squads / Phantom / ...>
**Outcome:** <state changes when it succeeds — DB rows written, on-chain PDAs touched, emails/webhooks sent>
**Preconditions:** <what must be true before the trigger fires — user logged in, contest open, balance >= fee>

## Sequence

1. **<step name>** — `path/to/file.rb:NN`
   - <one-line elaboration if behaviour is non-obvious>
2. **<step name>** — `path/to/controller.rb:NN`
   - enqueues `SomeJob` → `app/jobs/some_job.rb:NN`
3. **<step name>** — `path/to/service.rb:NN`
   - calls external <Stripe / Solana RPC / Resend>
4. ...

## Data touched

- `table_name.column` (read / write / insert / update)
- `another_table` (insert)
- on-chain: `<PDA name / instruction>` (read / cpi / sign+send)
- external: <Stripe payment intent / Resend email / Sentry event>

## Failure modes

- **<failure case>** — user-visible symptom → where it surfaces (log line, table, dashboard, Sentry)
- **<failure case>** — what the code does (retry / dead-letter / silent skip) → operator action required
- ...

## Related workflows

- [[other-workflow-slug]] — <how they connect — predecessor, successor, alternate path>

---

<!--
How to use this template:
- Copy to `docs/workflows/<kebab-case-name>.md`.
- Fill in every angle-bracket placeholder; delete any section that doesn't apply (rare).
- Cite file:line for EVERY step. Run `grep -n` if you forget the number; do not guess.
- Add a row to `docs/workflows/README.md` under the right category.
- If this workflow chains into another, add the [[slug]] cross-link both ways.
-->
