defmodule Petepete.Billing.CashPaymentsTest do
  use Petepete.DataCase, async: true

  import Ecto.Query
  import Petepete.BillingScenario

  alias Petepete.{Billing, Clock, Ledger}
  alias Petepete.Billing.{Bill, Session, TransitionError}
  alias Petepete.Ledger.{AuditLog, Txn}

  @t0 ~U[2026-10-06 03:00:00Z]
  @day 24 * 60 * 60

  setup do
    Clock.freeze(@t0)
    {:ok, issued()}
  end

  defp pay!(ctx, member, extra \\ []) do
    assert {:ok, result} = Billing.mark_paid_cash(ctx.bills[member.id].id, opts(ctx, extra))
    result
  end

  defp progress(ctx), do: Billing.session_progress(Repo.get!(Session, ctx.session.id))

  defp audit_rows(ctx, action),
    do: Repo.all(from a in AuditLog, where: a.group_id == ^ctx.group.id and a.action == ^action)

  defp txn_count(ctx), do: length(Ledger.txns(ctx.group.id))

  describe "mark_paid_cash/2" do
    test "pays an unpaid bill: ledger cash_received, bill paid via cash with a shared time",
         ctx do
      Clock.advance(600)
      %{bill: bill, txn: txn, replayed: false} = pay!(ctx, ctx.a)

      assert txn.kind == "cash_received"
      assert txn.actor_type == "host"
      assert txn.actor_user_id == ctx.user.id
      assert txn.inserted_at == bill.paid_at
      assert bill.paid_at == DateTime.add(@t0, 600, :second)

      assert {bill.status, bill.paid_via, bill.paid_txn_id} == {"paid", "cash", txn.id}
      assert reload(bill) == bill

      # +amount to the member, -amount to the host who received the cash.
      assert Enum.sort_by(txn.entries, & &1.amount) |> Enum.map(&{&1.member_id, &1.amount}) ==
               [{ctx.host.id, -34_000}, {ctx.a.id, 34_000}]

      assert balance(ctx, ctx.a) == 0
    end

    test "writes an audit row for the host", ctx do
      %{txn: txn} = pay!(ctx, ctx.a)

      assert [%{actor_user_id: uid, subject_id: id, metadata: meta}] =
               audit_rows(ctx, "bill.mark_paid_cash")

      assert {uid, id} == {ctx.user.id, txn.id}
      assert %{"amount" => 34_000, "previous_status" => "unpaid"} = meta
    end

    test "paying the last open bill makes the session Selesai", ctx do
      assert progress(ctx) == :issued
      pay!(ctx, ctx.a)
      assert progress(ctx) == :issued
      pay!(ctx, ctx.b)
      assert progress(ctx) == :settled
    end

    test "a needs_review bill is resolved by cash for its amount_due", ctx do
      bill = ctx.bills[ctx.a.id]
      attempt = attempt!(bill)

      assert {:ok, {:ok, :needs_review}} =
               Repo.transaction(fn ->
                 Billing.apply_gateway_payment(bill.id, %{
                   paid_amount: 10_000,
                   matches_expected: false,
                   idempotency_key: "gw-short",
                   attempt_id: attempt.id
                 })
               end)

      assert reload(bill).status == "needs_review"

      %{bill: paid, txn: txn} = pay!(ctx, ctx.a)

      assert {paid.status, paid.paid_via} == {"paid", "cash"}
      assert Enum.any?(txn.entries, &(&1.member_id == ctx.a.id and &1.amount == 34_000))
    end

    test "a paid or void bill is refused and posts nothing", ctx do
      pay!(ctx, ctx.a)
      before = txn_count(ctx)

      assert {:error, %TransitionError{entity: :bill, from: "paid", to: "paid"}} =
               Billing.mark_paid_cash(ctx.bills[ctx.a.id].id, opts(ctx))

      # The host's bill is Rp0 and already paid by credit: there is no cash to take.
      assert {:error, %TransitionError{from: "paid"}} =
               Billing.mark_paid_cash(ctx.bills[ctx.host.id].id, opts(ctx))

      {:ok, _} =
        Billing.void_issue(ctx.session.id, opts(ctx, reason: "salah"))

      assert {:error, %TransitionError{from: "void"}} =
               Billing.mark_paid_cash(ctx.bills[ctx.b.id].id, opts(ctx))

      assert txn_count(ctx) == before + 1
      assert length(audit_rows(ctx, "bill.mark_paid_cash")) == 1
    end

    test "unknown bills and a missing key", ctx do
      assert {:error, :not_found} = Billing.mark_paid_cash(0, opts(ctx))

      assert {:error, :idempotency_key_required} =
               Billing.mark_paid_cash(ctx.bills[ctx.a.id].id, opts(ctx, idempotency_key: ""))

      assert txn_count(ctx) == 1
    end

    test "the same key again returns the same txn: one txn, one audit row", ctx do
      first = pay!(ctx, ctx.a, idempotency_key: "cash-1")
      Clock.advance(60)
      again = pay!(ctx, ctx.a, idempotency_key: "cash-1")

      assert again.replayed == true
      assert again.txn.id == first.txn.id
      assert again.bill.paid_at == first.bill.paid_at
      assert txn_count(ctx) == 2
      assert length(audit_rows(ctx, "bill.mark_paid_cash")) == 1
    end

    test "a key already used for another bill or another kind is a conflict", ctx do
      pay!(ctx, ctx.a, idempotency_key: "cash-1")

      assert {:error, :idempotency_key_conflict} =
               Billing.mark_paid_cash(
                 ctx.bills[ctx.b.id].id,
                 opts(ctx, idempotency_key: "cash-1")
               )

      assert {:error, :idempotency_key_conflict} =
               Billing.mark_paid_cash(
                 ctx.bills[ctx.b.id].id,
                 opts(ctx, idempotency_key: Repo.get!(Txn, ctx.issue.txn.id).idempotency_key)
               )

      assert reload(ctx.bills[ctx.b.id]).status == "unpaid"
    end
  end

  describe "cancel_cash/2" do
    defp cancel!(ctx, member, extra \\ []) do
      assert {:ok, result} =
               Billing.cancel_cash(
                 ctx.bills[member.id].id,
                 opts(ctx, [reason: "salah orang"] ++ extra)
               )

      result
    end

    test "reverses the cash: bill unpaid with paid fields cleared, balance back", ctx do
      paid = pay!(ctx, ctx.a)
      Clock.advance(3600)
      %{bill: bill, txn: txn, replayed: false} = cancel!(ctx, ctx.a)

      assert txn.kind == "cash_payment_cancelled"
      assert txn.reverses_txn_id == paid.txn.id
      assert txn.reason == "salah orang"

      assert {bill.status, bill.paid_via, bill.paid_txn_id, bill.paid_at} ==
               {"unpaid", nil, nil, nil}

      assert reload(bill) == bill
      assert balance(ctx, ctx.a) == -34_000

      assert [%{metadata: %{"reason" => "salah orang", "cash_txn_id" => id}}] =
               audit_rows(ctx, "bill.cancel_cash")

      assert id == paid.txn.id
    end

    test "Selesai turns back into Ditagih, and cash can be taken again with a new key", ctx do
      pay!(ctx, ctx.a)
      pay!(ctx, ctx.b)
      assert progress(ctx) == :settled

      cancel!(ctx, ctx.b)
      assert progress(ctx) == :issued

      %{bill: bill} = pay!(ctx, ctx.b)
      assert bill.status == "paid"
      assert progress(ctx) == :settled
    end

    test "allowed exactly 24 hours after the cash time, refused one second later", ctx do
      pay!(ctx, ctx.a)
      pay!(ctx, ctx.b)

      Clock.freeze(DateTime.add(@t0, @day + 1, :second))
      before = txn_count(ctx)

      assert {:error, :undo_window_expired} =
               Billing.cancel_cash(ctx.bills[ctx.b.id].id, opts(ctx, reason: "telat"))

      assert reload(ctx.bills[ctx.b.id]).status == "paid"
      assert txn_count(ctx) == before
      assert audit_rows(ctx, "bill.cancel_cash") == []

      Clock.freeze(DateTime.add(@t0, @day, :second))
      assert %{bill: %{status: "unpaid"}} = cancel!(ctx, ctx.a)
    end

    test "the reason is required", ctx do
      pay!(ctx, ctx.a)

      for reason <- [nil, " "] do
        assert {:error, :reason_required} =
                 Billing.cancel_cash(ctx.bills[ctx.a.id].id, opts(ctx, reason: reason))
      end

      assert reload(ctx.bills[ctx.a.id]).status == "paid"
    end

    test "only a cash payment: unpaid, credit-paid, gateway-paid and void bills are refused",
         ctx do
      assert {:error, %TransitionError{from: "unpaid", to: "unpaid"}} =
               Billing.cancel_cash(ctx.bills[ctx.a.id].id, opts(ctx, reason: "x"))

      assert {:error, :not_cash_payment} =
               Billing.cancel_cash(ctx.bills[ctx.host.id].id, opts(ctx, reason: "x"))

      bill = ctx.bills[ctx.a.id]

      assert {:ok, {:ok, :paid}} =
               Repo.transaction(fn ->
                 Billing.apply_gateway_payment(bill.id, %{
                   paid_amount: 34_240,
                   matches_expected: true,
                   idempotency_key: "gw-ok",
                   attempt_id: attempt!(bill).id
                 })
               end)

      assert {:error, :not_cash_payment} =
               Billing.cancel_cash(bill.id, opts(ctx, reason: "x"))

      {:ok, _} = Billing.void_issue(ctx.session.id, opts(ctx, reason: "salah"))

      assert {:error, %TransitionError{from: "void"}} =
               Billing.cancel_cash(bill.id, opts(ctx, reason: "x"))
    end

    test "the same key again returns the same txn: one txn, one audit row", ctx do
      pay!(ctx, ctx.a)
      first = cancel!(ctx, ctx.a, idempotency_key: "undo-1")
      again = cancel!(ctx, ctx.a, idempotency_key: "undo-1")

      assert again.replayed == true
      assert again.txn.id == first.txn.id
      assert txn_count(ctx) == 3
      assert length(audit_rows(ctx, "bill.cancel_cash")) == 1
      assert reload(ctx.bills[ctx.a.id]).status == "unpaid"
    end

    test "a replay with another reason is a conflict", ctx do
      pay!(ctx, ctx.a)
      cancel!(ctx, ctx.a, idempotency_key: "undo-1")

      assert {:error, :idempotency_key_conflict} =
               Billing.cancel_cash(
                 ctx.bills[ctx.a.id].id,
                 opts(ctx, reason: "lain", idempotency_key: "undo-1")
               )
    end
  end

  test "bills of other sessions are untouched", ctx do
    pay!(ctx, ctx.a)
    assert Repo.aggregate(from(b in Bill, where: b.status == "paid"), :count) == 2
  end
end
