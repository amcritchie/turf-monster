# Merchant Application Answers — Turf Totals / Turf Monster

Canonical answers for high-risk merchant processor applications (Corepay /
PayKings / Durango, 2026-06). Keep every application consistent with this
sheet — underwriters cross-check answers against each other and against the
live site (https://app.turfmonster.media).

`[OPERATOR FILL]` marks blanks the operator must complete before submitting.

---

## Business description (use verbatim)

> Paid-entry fantasy sports contests of skill; users purchase contest-entry
> credits by card; prizes are USD-denominated.

Longer form, if the application allows:

> Turf Totals (operated by McRitchie Studio) runs paid-entry fantasy sports
> pick'em contests of skill around the 2026 FIFA World Cup. Users purchase
> contest-entry credits by card ($19 single / $49 three-pack), build an entry
> by selecting six team matchups, and compete against other entrants on the
> skill of their selections. Prizes are denominated in U.S. dollars per a
> payout table published before each contest opens, and are settled in USDC
> (a fully-reserved U.S. dollar stablecoin) with publicly verifiable payout
> records.

## Corporate details

| Field | Answer |
|---|---|
| Legal entity | [OPERATOR FILL — legal entity name + state of formation] |
| DBA | Turf Totals / Turf Monster |
| Website | https://app.turfmonster.media |
| Business address | [OPERATOR FILL — must match the address published on /contact, /about, and the footer] |
| Owner / principal | [OPERATOR FILL] |
| Support email | alex@turfmonster.media |
| Support phone | [OPERATOR FILL — if required by the processor] |
| Descriptor | TURF MONSTER [OPERATOR FILL — confirm exact descriptor at boarding; /terms card-dispute section currently says TURF MONSTER] |
| MCC | 7994 (expected — video amusement/games; processor may board as 7995-adjacent fantasy sports. Accept the processor's category guidance, do not argue for a retail MCC) |

## Volume / ticket profile

Pull actuals from the Stripe dashboard before filing; do not estimate from
memory.

| Field | Answer |
|---|---|
| Average ticket | $19 — [OPERATOR FILL — confirm blended average from Stripe; $49 trio purchases raise it] |
| High ticket | $49 |
| Monthly volume (current) | [OPERATOR FILL — Stripe actuals, trailing 3 months] |
| Monthly volume (requested) | [OPERATOR FILL — projection through the World Cup window, with basis] |
| Sales method | 100% e-commerce (card-not-present), single domain |
| Recurring billing | None — every purchase is a discrete, user-initiated checkout. No subscriptions, no negative option, no trials |
| Refund policy | Published at /terms#refunds: cancelled-before-lock contests refunded within 7 days; unused entry credits refundable on request; locked entries final |
| Chargeback history | Zero chargebacks to date [OPERATOR FILL — verify against Stripe disputes dashboard before signing] |

## Prior processor / termination disclosure (use verbatim)

> Our prior processor, Stripe, restricted the account under its platform-wide
> restricted-business category policy for fantasy sports / contest platforms.
> The restriction was a category determination, not conduct-based: the account
> had zero fraud flags and zero chargebacks. We are applying to processors
> whose underwriting supports this category.

Notes for the operator:
- Answer "yes" to "have you ever been terminated by a processor" questions —
  non-disclosure is the fastest route to a MATCH listing. The paragraph above
  is the disclosure.
- [OPERATOR FILL — confirm the exact wording Stripe used in its restriction
  email and attach it if the application allows supporting documents.]

## Licensing / legal posture (use verbatim)

> Turf Totals operates paid-entry fantasy contests of skill. Skill-based
> fantasy contests are lawful in the majority of U.S. states without a
> license; a minority of states either prohibit paid fantasy contests or
> require operator registration, and we exclude all of those states by IP
> geolocation rather than operating under registration. We are not a
> sportsbook: users never wager on game outcomes against the house; entrants
> compete against each other on the skill of their selections, and prize
> tables are fixed and published before each contest opens. We hold no
> gaming licenses and none are required in the states we serve.
> [OPERATOR FILL — have counsel review this paragraph before submission.]

## States served / excluded

> Paid entry is blocked by IP geolocation in: WA, ID, MT, LA, AZ, HI, NV, CA.
> The list is published at https://app.turfmonster.media/state-eligibility and
> in our Terms of Service, and is rendered from the same configuration the
> enforcement system reads. Age eligibility (18+; 19+ AL/NE; 21+ IA/MA/VA) is
> attested at account creation and recorded with a timestamp.

(CA pending operator confirmation — see operator decisions in the compliance
PR. If CA is NOT banned at submission time, remove it from this list AND from
the live GeoSetting row consistently.)

## Compliance summary (attach or paste where asked)

- Age attestation at signup, recorded per-account (`users.age_attested_at`).
- IP-geolocation state blocking on contest entry and fund movement.
- Responsible gaming page with 1-800-GAMBLER + NCPG links and a self-exclusion
  / deposit-limit policy: https://app.turfmonster.media/responsible-gaming
- AML/KYC policy: see `docs/underwriting/AML_KYC_POLICY.md`.
- One account per person (Terms-enforced; duplicate accounts suspended).
- Card purchases buy contest-entry credits only — cards never fund a
  withdrawable balance or purchase cryptocurrency. Prizes are USD-denominated
  and settled in USDC.
- Transparency hub for payout verification: https://app.turfmonster.media/transparency
