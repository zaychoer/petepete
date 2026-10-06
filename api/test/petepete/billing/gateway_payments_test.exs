defmodule Petepete.Billing.GatewayPaymentsTest do
  use Petepete.DataCase, async: true

  import Ecto.Query
  import Petepete.BillingScenario

  alias Petepete.{Billing, Clock, Ledger}
  alias Petepete.Ledger.Txn
  alias Petepete.Payments.PaymentAttempt

  @t0 ~U[2026-10-06 03:00:00Z]

  setup do
    Clock.freeze(@t0)
    ctx = issued()
    bill = ctx.bills[ctx.a.id]
    {:ok, Map.merge(ctx, %{bill: bill, attempt: attempt!(bill)})}
  end

  defp apply!(ctx, extra \\ %{}) do
    params =
      Map.merge(
        %{
          paid_amount: ctx.attempt.gross_amount,
          matches_expected: true,
          idempotency_key: "gw-#{System.unique_integer([:positive])}",
          attempt_id: ctx.attempt.id
        },
        extra
      )

    {:ok, outcome} =
      Repo.transaction(fn -> Billing.apply_gateway_payment(ctx.bill.id, params) end)

    outcome
  end

  defp txn_count(ctx), do: length(Ledger.txns(ctx.group.id))

  defp gateway_txns(ctx),
    do:
      Repo.all(
        from t in Txn, where: t.group_id == ^ctx.group.id and t.kind == "gateway_payment_received"
      )

  test "matching amount on an unpaid bill: ledger post, bill paid via gateway", ctx do
    Clock.advance(90)
    assert {:ok, :paid} = apply!(ctx)

    assert [txn] = gateway_txns(ctx)
    assert txn.actor_type == "gateway"

    bill = reload(ctx.bill)
    assert {bill.status, bill.paid_via, bill.paid_txn_id} == {"paid", "gateway", txn.id}
    assert bill.paid_at == DateTime.add(@t0, 90, :second)

    # The host nets amount_due: the fee is the payer's, so the books move amount_due.
    assert balance(ctx, ctx.a) == 0
    assert balance(ctx, ctx.host) == 66_000 - 34_000
    assert Repo.get!(PaymentAttempt, ctx.attempt.id).paid_amount == ctx.attempt.gross_amount
  end

  test "different amount on an unpaid bill: needs_review, nothing posted, paid_amount kept",
       ctx do
    before = txn_count(ctx)

    assert {:ok, :needs_review} = apply!(ctx, %{paid_amount: 30_000, matches_expected: false})

    bill = reload(ctx.bill)

    assert {bill.status, bill.paid_via, bill.paid_txn_id, bill.paid_at} ==
             {"needs_review", nil, nil, nil}

    assert txn_count(ctx) == before

    attempt = Repo.get!(PaymentAttempt, ctx.attempt.id)
    assert attempt.paid_amount == 30_000
    assert attempt.status == "pending"
  end

  test "a payment on an already paid bill is credit, the bill is untouched", ctx do
    {:ok, _} = Billing.mark_paid_cash(ctx.bill.id, opts(ctx))
    paid = reload(ctx.bill)

    assert {:ok, :overpaid} = apply!(ctx)

    assert reload(ctx.bill) == paid
    assert [txn] = gateway_txns(ctx)
    assert txn.ref_id == ctx.bill.id
    assert balance(ctx, ctx.a) == 34_000
  end

  test "a payment on a void bill becomes participant credit; the next issue consumes it", ctx do
    {:ok, _} = Billing.void_issue(ctx.session.id, opts(ctx, reason: "salah"))
    assert balance(ctx, ctx.a) == 0

    assert {:ok, :overpaid} = apply!(ctx)

    assert reload(ctx.bill).status == "void"
    assert balance(ctx, ctx.a) == 34_000

    assert {:ok, reissued} =
             Billing.issue(ctx.session.id, actor: {:host, ctx.user.id}, idempotency_key: "again")

    bill = Enum.find(reissued.bills, &(&1.member_id == ctx.a.id))
    assert {bill.credit_applied, bill.amount_due, bill.status} == {34_000, 0, "paid"}
  end

  test "a mismatching amount on a paid or void bill follows the third rule: credit", ctx do
    {:ok, _} = Billing.mark_paid_cash(ctx.bill.id, opts(ctx))

    assert {:ok, :overpaid} = apply!(ctx, %{paid_amount: 10_000, matches_expected: false})

    assert reload(ctx.bill).status == "paid"
    assert [_] = gateway_txns(ctx)
    assert Repo.get!(PaymentAttempt, ctx.attempt.id).paid_amount == 10_000
  end

  test "a needs_review bill stays for the host: another mismatch changes nothing, a match is credit",
       ctx do
    assert {:ok, :needs_review} = apply!(ctx, %{paid_amount: 30_000, matches_expected: false})
    assert {:ok, :needs_review} = apply!(ctx, %{paid_amount: 31_000, matches_expected: false})
    assert gateway_txns(ctx) == []

    assert {:ok, :overpaid} = apply!(ctx)
    assert reload(ctx.bill).status == "needs_review"
    assert [_] = gateway_txns(ctx)
  end

  test "the same key again posts no second txn and changes nothing", ctx do
    key = "gw-dup"
    assert {:ok, :paid} = apply!(ctx, %{idempotency_key: key})
    paid = reload(ctx.bill)
    before = txn_count(ctx)

    # Same notification again, or the bill moved on since (cash cancelled is not possible
    # for gateway payments, so the bill is still paid).
    assert {:ok, :paid} = apply!(ctx, %{idempotency_key: key})

    assert txn_count(ctx) == before
    assert reload(ctx.bill) == paid
  end

  test "a replayed credit key stays credit and posts nothing more", ctx do
    {:ok, _} = Billing.mark_paid_cash(ctx.bill.id, opts(ctx))

    assert {:ok, :overpaid} = apply!(ctx, %{idempotency_key: "gw-late"})
    before = txn_count(ctx)
    assert {:ok, :overpaid} = apply!(ctx, %{idempotency_key: "gw-late"})

    assert txn_count(ctx) == before
    assert length(gateway_txns(ctx)) == 1
  end

  test "an attempt of another bill is refused before anything is written", ctx do
    other = attempt!(ctx.bills[ctx.b.id])
    before = txn_count(ctx)

    assert {:ok, {:error, :attempt_not_found}} =
             Repo.transaction(fn ->
               Billing.apply_gateway_payment(ctx.bill.id, %{
                 paid_amount: ctx.attempt.gross_amount,
                 matches_expected: true,
                 idempotency_key: "gw-x",
                 attempt_id: other.id
               })
             end)

    assert reload(ctx.bill).status == "unpaid"
    assert txn_count(ctx) == before
    assert Repo.get!(PaymentAttempt, other.id).paid_amount == nil
  end

  test "ledger failures come back as errors with nothing changed", ctx do
    Repo.delete_all(Petepete.Groups.PayoutAccount)

    assert {:ok, {:error, :no_payout_account}} =
             Repo.transaction(fn ->
               Billing.apply_gateway_payment(ctx.bill.id, %{
                 paid_amount: ctx.attempt.gross_amount,
                 matches_expected: true,
                 idempotency_key: "gw-y",
                 attempt_id: ctx.attempt.id
               })
             end)

    assert reload(ctx.bill).status == "unpaid"
    assert Repo.get!(PaymentAttempt, ctx.attempt.id).paid_amount == nil
  end

  test "unknown bills", ctx do
    assert {:ok, {:error, :not_found}} =
             Repo.transaction(fn ->
               Billing.apply_gateway_payment(0, %{
                 paid_amount: 1,
                 matches_expected: true,
                 idempotency_key: "gw-z",
                 attempt_id: ctx.attempt.id
               })
             end)
  end
end
