# AML / KYC Policy — Turf Totals (McRitchie Studio)

One-page policy statement for merchant-processor underwriting (2026-06).
`[OPERATOR FILL]` marks blanks the operator must complete before attaching
this to an application.

Policy owner: [OPERATOR FILL — name/title]. Last reviewed: 2026-06.

## Identity at signup

- Every account requires a verified identity anchor: a verified email address
  (one-time magic link — clicking proves mailbox control), a Google account
  (Google-verified email), or a cryptographic Solana wallet signature.
- Every new account affirmatively attests legal age for skill contests in the
  user's state (18+; 19+ AL/NE; 21+ IA/MA/VA); the attestation is recorded
  with a timestamp on the account record.
- One account per person (Terms of Service). Accounts identified as
  duplicates are suspended and their entries voided.

## KYC before payout

- Posture: **no prize payout is released until the recipient passes KYC.**
  Before releasing any prize above the de-minimis threshold of
  $[OPERATOR FILL — e.g. 600], we collect and verify legal name, date of
  birth, and address [OPERATOR FILL — confirm threshold and whether a
  third-party IDV vendor (e.g. Persona/Veriff) will be used, or manual review
  by the operator at current volume].
- Payouts are manually reviewed today (low volume, single operator); every
  payout requires a 2-of-3 multisig release, so no single key — and no
  compromised automated system — can move prize funds.
- Tax reporting: where a user's annual net winnings meet IRS thresholds we
  collect a W-9 and issue 1099-MISC [OPERATOR FILL — confirm with accountant].

## Sanctions / OFAC screening

- Geographic scope is U.S.-only by IP geolocation; excluded U.S. states are
  blocked at entry and fund movement (list published at /state-eligibility).
- Intent (pre-payout control): payout wallet addresses are screened against
  OFAC SDN-listed addresses before release
  [OPERATOR FILL — select tooling: Chainalysis Free Sanctions Screening API /
  TRM / manual SDN list check at current volume, and record the choice here].
- Any positive screen freezes the payout and the account pending review.

## Card-payment scope (relevant to the processor)

- Cards purchase **contest-entry credits only** ($19 / $49 packs). Cards
  never fund a withdrawable balance, never purchase cryptocurrency, and there
  is no card-to-crypto off-ramp: a credit's only redemption is one contest
  entry.
- This bounds card-side AML exposure: card funds cannot exit except as a
  contest prize won on skill, which then passes the KYC-before-payout gate.

## Monitoring & limits

- All payments and on-chain transactions are logged with immutable audit
  records (every Stripe and Solana RPC call is captured server-side).
- Velocity anomalies (rapid repeat purchases, many accounts on one device/IP,
  referral-ring patterns) are reviewed manually; rate limiting throttles
  abusive request patterns automatically.
- Deposit limits and self-exclusion are available to every user on request
  (published at /responsible-gaming) and are honored within one business day.

## Geographic enforcement

- IP geolocation gates contest entry and fund movement per the published
  state-eligibility list; the public list renders from the same configuration
  the enforcement reads, so policy and enforcement cannot drift.
- VPN/proxy circumvention is prohibited by the Terms of Service and grounds
  for suspension and forfeiture.
