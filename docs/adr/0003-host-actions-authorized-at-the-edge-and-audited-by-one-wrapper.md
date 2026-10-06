---
status: accepted
---

# Host actions are authorized at the HTTP edge and audited by one wrapper

Plugs authorize the caller (`Groups.authorize_actor/3`) and hand contexts a `%Petepete.Actor{}` that can only be built that way; Billing, Ledger and Payments never re-check roles. Every host action that changes money runs through `Petepete.HostAction.run/4`, which owns the database transaction, rolls back on error, and writes the `audit_log` row unless the Ledger reported an idempotent replay. We chose this because authorization lived in three plugs, three in-context calls and one inline controller check, and `Audit.record/5` had seven hand-written call sites whose rules (same transaction, skip on replay, never forget) existed only in a moduledoc; the code review already found one missed audit row (`issue`).

## Considered Options

- **Authorize inside every command**: contexts take a Scope and call `Groups.authorize` themselves. Rejected: webhooks and Oban jobs have no Scope, and Billing money commands already trust their caller.
- **Drop `audit_log` rows for ledger-backed actions** (the Ledger txn already holds actor, kind, reason and ref): smaller, but contradicts the spec's "all host money actions in `audit_log`" and LDG-04.
- **Keep seven explicit `Audit.record` calls**: nothing enforces the rules.

## Consequences

- A command called without going through an authorizing plug is unprotected; the `%Actor{}` type makes that hard to do by accident, and a router test requires every non-GET `/api` route to be classified (host money, host other, member, self, public).
- A table-driven contract test over every host money action replaces the per-endpoint audit assertions: one audit row, none on replay, rollback on failure, non-host rejected.
- Non-money host writes (cost and attendance edits, guests, invite reset) get edge authorization but no audit row.
- `{:host, user_id}` tuples are replaced everywhere with the struct (no compatibility shim).
