---
status: accepted
---

# The Ledger posts inside the caller's transaction, under a per-group lock

`Ledger.record/2` never opens or commits its own database transaction: it runs inside the `Ecto.Multi` or `Repo.transaction` of the module that caused the money event, so a gateway webhook commits its `payment_events` row, the Ledger txn, and the bill change together or not at all, and a crash can never leave a posted txn beside an unpaid bill. Every `record/2` takes a per-group Postgres advisory transaction lock, always after any row locks the caller already holds (for example `bills … FOR UPDATE`), so kas spends cannot overdraw the kas and two concurrent session-billed events cannot spend the same credit twice, and the fixed order prevents deadlocks with the webhook flow.

## Considered Options

- **Ledger commits its own transaction**: callers could not make "post + update the bill" atomic, which breaks webhook idempotency.
- **Lock only for events that read balances (session billed, kas spend)**: cheaper, but every event kind would then need its own argument for why it is safe to run concurrently. Groups are small, so serialising all postings per group costs nothing.

## Consequences

- Ledger tests that need a rollback run inside the test sandbox transaction; the caller owns commit.
- The session-billed result returns each participant's balance from just before the posting, so Billing derives credit without taking the lock itself.
- Kas is allowed to go negative when a session's bills are cancelled after its remainder was spent; only `kas_spend` is checked against the kas balance.
