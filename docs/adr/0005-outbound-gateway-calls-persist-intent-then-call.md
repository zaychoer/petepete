---
status: accepted
---

# Outbound gateway calls persist intent, call, then settle; one reconciler re-drives stuck intents

Every outbound gateway call (payment attempt creation, withdrawal, payout account registration) follows the same order: commit a durable intent row with status `pending` (or `registering`), call the gateway outside the transaction using a stable reference derivable from the row, then settle the row with the outcome. Each kind implements a behaviour (`Petepete.Payments.OutboundIntent`) with `prepare`, `request`, `settle` and `stuck`; one runner (`Petepete.Payments.IntentRunner`) executes the steps, and one Oban cron reconciler (`Petepete.Payments.IntentReconciler`) sweeps stuck intents every 5 minutes. We chose this because the review-fix pass applied the persist-call-settle rule by hand to two modules, a stuck-pending reconciler existed for neither, and the real gateway adapters (Xendit or Midtrans) will multiply the callers.

## Intent state lives on the domain rows

Payment attempts, withdrawals and payout accounts already carry a status column that is the durable intent. A generic outbox table would be a second source of truth that can disagree with the domain row. Each kind module exposes a `stuck/1` query; the reconciler unions the three.

## Recovery rules

- **Payment attempts**: a stuck `pending` attempt (no `provider_ref`, older than the threshold) is re-driven with its stable `external_id`; after 3 failures it is marked `failed`. The payer's retry creates a new seq.
- **Withdrawals**: a stuck `pending` withdrawal is moved to `needs_review` and reported to Sentry; it is never re-driven automatically, because a provider that does not de-duplicate on our reference could pay out twice. An optional adapter callback `withdrawal_status(reference)` returning `:submitted | :managed | :not_found` unlocks automatic settlement when the adapter supports it; `:not_found` allows a re-drive. The Fake implements it. This is the only safe path until the provider's idempotency semantics are verified.
- **Payout registration**: the full bank account number is not stored (only `last4`), so a stuck `registering` row cannot be re-driven. The reconciler marks it `failed` after the threshold; the host resubmits with a new Idempotency-Key.

## Considered Options

- **Generic `outbound_requests` table**: second source of truth, can disagree with domain rows.
- **Call then commit** (the original payout registration order): a commit failure after the provider accepted orphans the resource at the provider with no local record.
- **Auto re-drive all kinds**: unsafe for withdrawals without verified provider de-duplication.
- **Re-drive payout registration**: requires storing encrypted PII (full account number) for a case that needs only one manual retry.

## Consequences

- New statuses: `withdrawals.needs_review` and `payout_accounts.registering`, added to `PetepeteWeb.Labels`, contract samples and the app.
- Threshold (10 min) and max retries (3) are configurable in `config :petepete, Petepete.Payments`.
- Every `needs_review` transition and exhausted retry reports a Sentry message (ids and reference only, via `PhoneMask`).
- The `Gateway` behaviour gains one optional callback: `withdrawal_status/1`.
