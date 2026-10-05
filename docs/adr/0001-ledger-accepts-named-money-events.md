---
status: accepted
---

# The Ledger accepts named money events, not generic postings

Callers (Billing, Payments, host actions) hand the Ledger one of a closed set of money events — session billed, gateway payment received, cash received, settlement between members, kas spend, session bills cancelled, cash payment cancelled, correction — and the Ledger alone turns each into balanced entries and enforces that kind's rules. We chose this so that sign conventions, the kas-has-no-member rule, and "what may be undone" live in one module instead of leaking to every caller; the cost is that the Ledger knows Billing's vocabulary (a session billed carries per-member shares, fronted costs, and the kas remainder) and must change when a new kind of money movement appears.

## Considered Options

- **Generic postings** (account, signed amount, checked only for a zero sum): keeps the Ledger ignorant of Billing, but every caller must know the sign and kas conventions — the leak this decision removes. The database zero-sum trigger stays as a backstop, not as the rule.
- **Transfers** (from, to, amount): balanced by construction and fine for payments, cash, settlements, and kas spends, but a session billed has no natural pairing between N participants and M payers plus the kas.
