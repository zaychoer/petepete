defmodule Petepete.Billing.CommandsConcurrencyTest do
  # Real, committed transactions on separate connections, outside the sandbox (see
  # InvoicingConcurrencyTest). Exercises the lock order session -> bills -> ledger.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Petepete.BillingScenario

  alias Petepete.{Billing, Ledger, Repo}
  alias Petepete.Ledger.{AuditLog, Txn}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Repo.query!(
        "TRUNCATE audit_log, ledger_entries, ledger_txns, payment_attempts, bills, " <>
          "session_participants, cost_item_members, cost_items, sessions, events, " <>
          "payout_accounts, group_members, groups, users CASCADE"
      )

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    {:ok, issued()}
  end

  defp await(tasks), do: Task.await_many(tasks, 10_000)

  test "two voids with one key: one txn, one audit row, the loser is a replay", ctx do
    opts = opts(ctx, reason: "salah", idempotency_key: "void-same")

    results =
      await(for _ <- 1..2, do: Task.async(fn -> Billing.void_issue(ctx.session.id, opts) end))

    assert [{:ok, %{replayed: false} = first}, {:ok, %{replayed: true} = second}] =
             Enum.sort_by(results, fn {:ok, r} -> r.replayed end)

    assert first.txn.id == second.txn.id
    assert Repo.aggregate(from(t in Txn, where: t.kind == "session_bills_cancelled"), :count) == 1
    assert Repo.aggregate(from(a in AuditLog, where: a.action != "session.issue"), :count) == 1
  end

  test "two cash requests with one key: one txn, one audit row", ctx do
    bill = ctx.bills[ctx.a.id]
    opts = opts(ctx, idempotency_key: "cash-same")

    results =
      await(for _ <- 1..2, do: Task.async(fn -> Billing.mark_paid_cash(bill.id, opts) end))

    assert [{:ok, %{replayed: false}}, {:ok, %{replayed: true}}] =
             Enum.sort_by(results, fn {:ok, r} -> r.replayed end)

    assert Repo.aggregate(from(t in Txn, where: t.kind == "cash_received"), :count) == 1
    assert Repo.aggregate(from(a in AuditLog, where: a.action != "session.issue"), :count) == 1
  end

  test "a webhook payment racing a void never deadlocks and leaves the same credit", ctx do
    bill = ctx.bills[ctx.a.id]
    attempt = attempt!(bill)

    void =
      Task.async(fn -> Billing.void_issue(ctx.session.id, opts(ctx, reason: "salah")) end)

    webhook =
      Task.async(fn ->
        Repo.transaction(fn ->
          # The webhook locks the bill first, as the lock order prescribes for it.
          Billing.lock_bills([bill.id])

          Billing.apply_gateway_payment(bill.id, %{
            paid_amount: attempt.gross_amount,
            matches_expected: true,
            idempotency_key: "gw-race",
            attempt_id: attempt.id
          })
        end)
      end)

    assert [{:ok, _}, {:ok, {:ok, outcome}}] = await([void, webhook])
    assert outcome in [:paid, :overpaid]

    # Paid then voided, or voided then credited: either way the Rp34.000 is credit.
    assert Ledger.balances(ctx.group.id).members[ctx.a.id] == 34_000
    assert Repo.get!(Petepete.Billing.Bill, bill.id).status == "void"
  end
end
