# Petepete

Petepete splits the costs of a recurring sports group's sessions among the people who attended, collects payment, and keeps the group's books.

## Language

### People and groups

**Group**:
A recurring sports group with one shared set of books.
_Avoid_: Team, club, community

**Host**:
The member who runs a group and is the only one who can change its money.
_Avoid_: Admin, organizer, owner

**Member**:
Anyone on a group's roster, with or without an app account; guests are members too.
_Avoid_: User (a user is a login), participant (only those at a session)

### Sessions and bills

**Event**:
What a group does, regularly or once, such as Thursday futsal.
_Avoid_: Schedule, activity, match

**Session**:
One occurrence of an Event on a date, with its costs, attendance and bills.
_Avoid_: Match, game, meeting

**Bill**:
One member's share of a Session.
_Avoid_: Invoice, tagihan (UI only), debt

**Payment attempt**:
One request to pay a Bill through the gateway.
_Avoid_: Payment (that is the money event), transaction

### Books

**Ledger**:
A group's append-only record of every money movement between its members and its kas.
_Avoid_: Journal, wallet

**Kas**:
The group's shared pot, holding rounding remainders and paying for shared purchases; it belongs to no member.
_Avoid_: Treasury, group balance, fund

**Money event**:
One named thing that moves money in a group: session billed, gateway payment received, cash received, settlement between members, kas spend, session bills cancelled, cash payment cancelled, or correction.
_Avoid_: Transaction (that is the ledger's record of it), posting, entry

**Payout account owner**:
The member whose gateway account receives a group's online payments, and so holds that money in the books.
_Avoid_: Merchant, recipient, treasurer

**Ledger txn**:
The ledger's balanced record of exactly one money event.
_Avoid_: Transaction (ambiguous with database transactions), journal entry

**Balance**:
What a member or the kas holds in the books: negative means the member owes the group, positive means credit, and a negative balance for the payout account owner means they are holding the group's money.
_Avoid_: Saldo (UI only), debt, wallet

**Credit**:
A member's positive balance, applied automatically to reduce their next bill.
_Avoid_: Deposit, top-up, wallet balance

**Fronted cost**:
A session cost a member paid out of pocket on the group's behalf, credited to them when the session is billed.
_Avoid_: Talangan (UI only), advance, reimbursement

**Actor**:
Who caused a money event: a host or the payment gateway.
_Avoid_: User, initiator

**Host action**:
A change to a group's money made by its host, recorded in the audit log.
_Avoid_: Admin action, host operation

### Undoing

**Correction**:
The host undoing a settlement or a kas spend; other money events are undone only by their own actions (cancelling a session's bills, cancelling a cash payment) and gateway payments are never undone.
_Avoid_: Koreksi (UI only), reversal (the ledger mechanism), refund
