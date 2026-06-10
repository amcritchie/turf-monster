# PayPal / Venmo Onramp — go-live runbook

PayPal-rails replacement for the (blocked) Stripe account: Venmo + PayPal
buttons backed by Orders v2. Built sandbox-first and fully flag-gated —
`PAYMENT_PROVIDER` unset means Stripe behavior is unchanged.

## Architecture (backend)

| Piece | File |
|---|---|
| Provider flag | `app/services/payments.rb` (`Payments.provider`, default `"stripe"`) |
| REST client (OAuth2 + Orders v2 + webhook verify) | `app/services/paypal/client.rb` — every call audited via `OutboundRequest` (service `paypal`) |
| Audit model | `app/models/paypal_purchase.rb` (`pending → captured → minted`; `refunded`/`failed`) |
| Order create / capture endpoints | `TokensController#paypal_order` / `#paypal_capture` (POST, JSON) |
| Status polling | `GET /tokens/status?order_id=…` (same payload as the Stripe `session_id` path) |
| Webhooks | `Webhooks::PaypalController` at `POST /webhooks/paypal` |
| Mint | `TokenPurchaseJob` (`purchase_type: "paypal"`, source_ref `paypal:<purchase_id>:<i>`) |
| Exactly-once gate | `PaypalPurchase#begin_fulfillment!` (atomic `pending → captured` CAS) via `Paypal::Fulfillment` |
| Boot guards | `config/initializers/paypal.rb` (OPSEC-032 parity) |

Fulfillment fires on `PAYMENT.CAPTURE.COMPLETED`. `CHECKOUT.ORDER.APPROVED` is
the client-died fallback (server-side capture when our purchase is still
pending). `PAYMENT.CAPTURE.DENIED` → failed. `PAYMENT.CAPTURE.REFUNDED` →
refunded + account frozen. `CUSTOMER.DISPUTE.CREATED` → payment-risk flag +
frozen (Stripe OPSEC-036 / B4 parity).

## Go-live gate — DO NOT skip

**Real-money gaming requires PayPal's pre-approval.** A PayPal Business
account accepting contest-entry payments without the gambling/skill-gaming
approval gets limited/frozen, with funds held 180 days. Before flipping
anything live:

1. PayPal Business account (US entity) in good standing.
2. Submit the skill-gaming/real-money application via PayPal merchant support
   and receive WRITTEN approval for turfmonster.media.
3. Only then proceed below.

## Live credentials + webhook

1. developer.paypal.com → Apps & Credentials → **Live** tab → Create App.
   Capture **Client ID** + **Secret**.
2. Same app → Webhooks → Add webhook:
   `https://app.turfmonster.media/webhooks/paypal`, subscribed to:
   `PAYMENT.CAPTURE.COMPLETED`, `CHECKOUT.ORDER.APPROVED`,
   `PAYMENT.CAPTURE.DENIED`, `PAYMENT.CAPTURE.REFUNDED`,
   `CUSTOMER.DISPUTE.CREATED`.
3. Capture the **Webhook ID** shown after saving — that is `PAYPAL_WEBHOOK_ID`
   (signature verification fails closed without it).

## Heroku flip

```sh
heroku config:set -a turf-monster-mainnet \
  PAYPAL_ENV=live \
  PAYPAL_CLIENT_ID=… \
  PAYPAL_CLIENT_SECRET=… \
  PAYPAL_WEBHOOK_ID=…
# the actual switch — until this, everything above is inert:
heroku config:set -a turf-monster-mainnet PAYMENT_PROVIDER=paypal
```

Boot guards (initializer): when `PAYMENT_PROVIDER=paypal` in production,
`PAYPAL_ENV` must be `live` and all three creds present or the app refuses to
boot. Roll back instantly with `PAYMENT_PROVIDER=stripe` (or unset).

## Post-flip smoke test

- Buy a `single` pack with a real account on **desktop** — the desktop Venmo
  flow is a QR code scanned from the Venmo app, and **sandbox cannot simulate
  QR at all**, so this is the first time that path runs. Verify: order →
  capture → `PaypalPurchase` minted → tokens visible in navbar.
- Check `/admin/outbound_requests?service=paypal` for the call trail and
  `grep "\[tokens\] paypal"` in logs.
- Webhook delivery: developer dashboard → Webhooks → Events shows 200s.

## Sandbox setup (local dev)

1. Sandbox app creds from the **Sandbox** tab → `.env`:
   `PAYPAL_ENV=sandbox`, `PAYPAL_CLIENT_ID/SECRET`, `PAYMENT_PROVIDER=paypal`.
2. JS SDK URL needs `&buyer-country=US` in sandbox ONLY (invalid in prod) or
   the Venmo button never renders.
3. Buyer logins: sandbox **Personal** account from developer.paypal.com →
   Testing Tools → Sandbox Accounts.
4. Webhooks locally: register a tunnel URL (or use the dashboard **Webhook
   simulator**) against the SANDBOX app and put that webhook id in
   `PAYPAL_WEBHOOK_ID`. Note the simulator sends generic payloads — they
   verify but won't match a real purchase row.
5. Amount-triggered sandbox errors: $12.34 insufficient funds, $21.43 account
   closed, $10.23 suspected fraud, $13.42 generic decline.
6. Sandbox CANNOT exercise: desktop QR, vaulted repeat purchases, disputes/
   settlement reporting.

## Production guards summary

- `Payments.paypal?` && creds present gate both token endpoints (else 422).
- Webhook signature verified via PayPal's verify-webhook-signature API with
  the RAW request body (fails closed when `PAYPAL_WEBHOOK_ID` unset).
- Sandbox events rejected in production (OPSEC-033 parity).
- Amounts validated server-side against `StripePurchase::PACKS` — capture must
  be `COMPLETED`, `USD`, exact pack amount, or no mint.
- Rate limits: 10/min/IP on order+capture, 100/min/IP on the webhook.
