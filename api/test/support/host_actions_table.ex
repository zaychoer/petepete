defmodule PetepeteWeb.HostActionsTable do
  @moduledoc """
  The table of every host money action reachable over HTTP (ADR-0003), shared by
  `PetepeteWeb.HostActionsContractTest` (which runs every row through the same contract) and
  `PetepeteWeb.RouterClassificationTest` (which fails when a `:host_money` route has no row).

  Adding a host money route means adding a row here; nothing else enforces its contract.

  A row is a map:

    * `:name` - label shown in failures.
    * `:route` - `{verb, router_path}` exactly as `PetepeteWeb.Router.__routes__/0` reports it.
    * `:audit` - the `audit_log` actions one successful request writes, sorted. A replay writes none.
    * `:subject` - the `subject_type` of the audit rows.
    * `:created` - status of the first successful request (default 201; a replay is always 200).
    * `:replay_drops` - response keys a replay legitimately does not repeat (default none).
    * `:setup` - `(base -> ctx)`: builds the rows the request needs; `ctx` is `base` plus extras.
    * `:request` - `(ctx -> {path, body})` of the accepted request.
    * `:reject` - `(ctx -> {path, body, status})`: a request the domain refuses; it may prepare
      the state it needs. Must write no audit row and no ledger txn.

  `base/0` builds the group the rows run in: `group`, its `host` member (and `host_user`),
  a plain `member` (`member_user`) and the host of another group (`outsider_user`).
  """
  import Petepete.Fixtures

  alias Petepete.Billing
  alias Petepete.Ledger.HostActions

  @type row :: %{
          name: String.t(),
          route: {atom(), String.t()},
          audit: [String.t()],
          subject: String.t(),
          created: pos_integer(),
          replay_drops: [String.t()],
          setup: (map() -> map()),
          request: (map() -> {String.t(), map()}),
          reject: (map() -> {String.t(), map(), pos_integer()})
        }

  @doc "A group with a host, a plain member and an outsider (host of another group)."
  def base do
    group = group_fixture()
    host_user = user_fixture(phone: valid_phone())
    member_user = user_fixture(phone: valid_phone())
    outsider_user = user_fixture(phone: valid_phone())
    host = member_fixture(group, role: "host", user: host_user)
    member_fixture(group, role: "member", user: member_user)
    member_fixture(group_fixture(), role: "host", user: outsider_user)

    %{
      group: group,
      host: host,
      host_user: host_user,
      member_user: member_user,
      outsider_user: outsider_user
    }
  end

  @doc "Every row, in route order."
  @spec rows() :: [row()]
  def rows do
    [
      %{
        name: "issue",
        route: {:post, "/api/sessions/:id/issue"},
        audit: ["session.issue"],
        subject: "session",
        created: 200,
        setup: &draft_session/1,
        request: fn ctx -> {"/api/sessions/#{ctx.session.id}/issue", %{}} end,
        reject: fn ctx ->
          empty = session_fixture(event_fixture(ctx.group))
          {"/api/sessions/#{empty.id}/issue", %{}, 422}
        end
      },
      %{
        name: "void",
        route: {:post, "/api/sessions/:id/void"},
        audit: ["session.void_issue"],
        subject: "txn",
        replay_drops: ["voided_bill_ids"],
        setup: &issued_session/1,
        request: fn ctx -> {"/api/sessions/#{ctx.session.id}/void", %{reason: "salah input"}} end,
        reject: fn ctx ->
          draft = session_fixture(event_fixture(ctx.group))
          {"/api/sessions/#{draft.id}/void", %{reason: "salah input"}, 409}
        end
      },
      %{
        name: "cash",
        route: {:post, "/api/bills/:id/cash"},
        audit: ["bill.mark_paid_cash"],
        subject: "txn",
        setup: &issued_session/1,
        request: fn ctx -> {"/api/bills/#{ctx.bill.id}/cash", %{}} end,
        # The host's own bill is Rp0, already paid by credit.
        reject: fn ctx -> {"/api/bills/#{ctx.host_bill.id}/cash", %{}, 409} end
      },
      %{
        name: "cash cancel",
        route: {:post, "/api/bills/:id/cash/cancel"},
        audit: ["bill.cancel_cash"],
        subject: "txn",
        setup: fn base ->
          ctx = issued_session(base)

          {:ok, _} =
            Billing.mark_paid_cash(ctx.bill.id,
              actor: host_actor(ctx.group, ctx.host),
              idempotency_key: "setup-cash-#{uniq()}"
            )

          ctx
        end,
        request: fn ctx ->
          {"/api/bills/#{ctx.bill.id}/cash/cancel", %{reason: "salah tandai"}}
        end,
        # Another member's bill was never paid in cash.
        reject: fn ctx ->
          {"/api/bills/#{ctx.other_bill.id}/cash/cancel", %{reason: "salah tandai"}, 409}
        end
      },
      %{
        name: "settlement",
        route: {:post, "/api/groups/:group_id/settlements"},
        audit: ["settlement.record"],
        subject: "txn",
        setup: &two_members/1,
        request: fn ctx ->
          {"/api/groups/#{ctx.group.id}/settlements",
           %{from_member_id: ctx.andi.id, to_member_id: ctx.budi.id, amount: 45_000}}
        end,
        reject: fn ctx ->
          {"/api/groups/#{ctx.group.id}/settlements",
           %{from_member_id: ctx.andi.id, to_member_id: ctx.andi.id, amount: 45_000}, 422}
        end
      },
      %{
        name: "kas spend",
        route: {:post, "/api/groups/:group_id/kas-spends"},
        audit: ["kas_spend.record"],
        subject: "txn",
        # Issuing a session puts its Rp2.000 remainder into kas.
        setup: &issued_session/1,
        request: fn ctx ->
          {"/api/groups/#{ctx.group.id}/kas-spends",
           %{member_id: ctx.bill.member_id, amount: 1_000, note: "bola"}}
        end,
        reject: fn ctx ->
          {"/api/groups/#{ctx.group.id}/kas-spends",
           %{member_id: ctx.bill.member_id, amount: 2_001, note: "bola"}, 422}
        end
      },
      %{
        name: "correction",
        route: {:post, "/api/txns/:id/correction"},
        audit: ["txn.correct"],
        subject: "txn",
        setup: fn base ->
          ctx = base |> issued_session() |> Map.merge(two_members(base))

          {:ok, %{txn: settlement}} =
            HostActions.record_settlement(
              host_actor(ctx.group, ctx.host),
              ctx.group.id,
              "setup-settlement-#{uniq()}",
              %{payer_member_id: ctx.andi.id, payee_member_id: ctx.budi.id, amount: 45_000}
            )

          Map.put(ctx, :settlement, settlement)
        end,
        request: fn ctx ->
          {"/api/txns/#{ctx.settlement.id}/correction", %{reason: "salah orang"}}
        end,
        # A session bill is not undoable by correction.
        reject: fn ctx ->
          {"/api/txns/#{ctx.issue.txn.id}/correction", %{reason: "salah orang"}, 422}
        end
      },
      %{
        name: "withdrawal request",
        route: {:post, "/api/groups/:group_id/withdrawals"},
        audit: ["withdrawal.request", "withdrawal.submitted"],
        subject: "withdrawal",
        setup: fn base ->
          Map.put(base, :account, payout_account_fixture(base.group, base.host, status: "active"))
        end,
        request: fn ctx -> {"/api/groups/#{ctx.group.id}/withdrawals", %{amount: 100_000}} end,
        # More than the fake gateway's balance (`withdrawal_balance/0`).
        reject: fn ctx ->
          {"/api/groups/#{ctx.group.id}/withdrawals", %{amount: withdrawal_balance() + 1}, 422}
        end
      },
      %{
        name: "payout account registration",
        route: {:post, "/api/groups/:group_id/payout-account"},
        audit: ["payout_account.register"],
        subject: "payout_account",
        setup: & &1,
        request: fn ctx ->
          {"/api/groups/#{ctx.group.id}/payout-account",
           %{bank_name: "BCA", account_number: "1234567890", account_holder_name: "Budi"}}
        end,
        reject: fn ctx ->
          {"/api/groups/#{ctx.group.id}/payout-account",
           %{bank_name: "BCA", account_number: "12", account_holder_name: "Budi"}, 422}
        end
      }
    ]
  end

  @doc "The fake gateway balance the withdrawal row runs against."
  def withdrawal_balance, do: 500_000

  # A draft session with the host and two members attending and a Rp100.000 cost.
  defp draft_session(base) do
    [a, b] = for _ <- 1..2, do: member_fixture(base.group, role: "member")
    session = session_fixture(event_fixture(base.group))
    for m <- [base.host, a, b], do: attendance_fixture(session, m)
    cost_item_fixture(session, amount: 100_000, paid_by: base.host)
    Map.merge(base, %{session: session, a: a, b: b})
  end

  # `draft_session/1`, issued: `bill` is `a`'s unpaid bill, `other_bill` is `b`'s,
  # `host_bill` the host's (Rp0, paid by credit).
  defp issued_session(base) do
    ctx = draft_session(base)

    {:ok, issue} =
      Billing.issue(ctx.session.id,
        actor: host_actor(ctx.group, ctx.host),
        idempotency_key: "setup-issue-#{uniq()}"
      )

    bill_of = fn member -> Enum.find(issue.bills, &(&1.member_id == member.id)) end

    Map.merge(ctx, %{
      issue: issue,
      bill: bill_of.(ctx.a),
      other_bill: bill_of.(ctx.b),
      host_bill: bill_of.(ctx.host)
    })
  end

  defp two_members(base) do
    Map.merge(base, %{
      andi: member_fixture(base.group, role: "member"),
      budi: member_fixture(base.group, role: "member")
    })
  end
end
