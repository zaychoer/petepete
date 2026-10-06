defmodule Petepete.Billing.VoidingTest do
  use Petepete.DataCase, async: true

  import Ecto.Query
  import Petepete.BillingScenario
  import Petepete.Fixtures, only: [uniq: 0]

  alias Petepete.{Billing, Clock, Ledger}
  alias Petepete.Billing.{Bill, Session, TransitionError}
  alias Petepete.Ledger.{AuditLog, Txn}
  alias Petepete.Ledger.Event.KasSpend
  alias Petepete.Payments.PaymentAttempt

  @t0 ~U[2026-10-06 03:00:00Z]

  setup do
    Clock.freeze(@t0)
    {:ok, issued()}
  end

  defp void!(ctx, extra \\ []) do
    assert {:ok, result} =
             Billing.void_issue(ctx.session.id, opts(ctx, [reason: "salah hitung"] ++ extra))

    result
  end

  defp audit_rows(ctx, action),
    do: Repo.all(from a in AuditLog, where: a.group_id == ^ctx.group.id and a.action == ^action)

  defp txn_count(ctx), do: length(Ledger.txns(ctx.group.id))

  test "voids the bills, reverts the session to draft and posts the reversing txn", ctx do
    result = void!(ctx)

    assert result.replayed == false
    assert result.txn.kind == "session_bills_cancelled"
    assert result.txn.reverses_txn_id == ctx.issue.txn.id
    assert result.txn.reason == "salah hitung"
    assert result.session.status == "draft"

    assert Enum.sort(result.voided_bill_ids) ==
             Enum.map(ctx.issue.bills, & &1.id) |> Enum.sort()

    assert Repo.all(from b in Bill, where: b.session_id == ^ctx.session.id, select: b.status) ==
             ["void", "void", "void"]

    assert %Session{status: "draft"} = Repo.get!(Session, ctx.session.id)

    assert Ledger.balances(ctx.group.id) == %{
             kas: 0,
             members: Map.new([ctx.host, ctx.a, ctx.b], &{&1.id, 0})
           }
  end

  test "writes the audit row with the reason", ctx do
    result = void!(ctx)

    assert [%{actor_user_id: uid, subject_type: "txn", subject_id: id, metadata: meta}] =
             audit_rows(ctx, "session.void_issue")

    assert uid == ctx.user.id
    assert id == result.txn.id
    assert %{"reason" => "salah hitung", "session_id" => _, "voided_bill_ids" => [_, _, _]} = meta
  end

  test "a settled session can be voided; cash already taken stays as credit", ctx do
    for m <- [ctx.a, ctx.b] do
      {:ok, _} = Billing.mark_paid_cash(ctx.bills[m.id].id, opts(ctx))
    end

    assert Billing.session_progress(Repo.get!(Session, ctx.session.id)) == :settled

    void!(ctx)

    assert balance(ctx, ctx.a) == 34_000
    assert balance(ctx, ctx.b) == 34_000
    assert balance(ctx, ctx.host) == -68_000
  end

  test "the kas may go negative", ctx do
    {:ok, {:ok, _}} =
      Repo.transaction(fn ->
        Ledger.record({:host, ctx.user.id}, %KasSpend{
          idempotency_key: "spend-#{uniq()}",
          group_id: ctx.group.id,
          member_id: ctx.host.id,
          amount: 2_000
        })
      end)

    void!(ctx)
    assert Ledger.balances(ctx.group.id).kas == -2_000
  end

  test "pending attempts of the bills become cancelled; settled ones stay", ctx do
    bill_a = ctx.bills[ctx.a.id]
    bill_b = ctx.bills[ctx.b.id]
    pending = attempt!(bill_a, seq: 1)
    expired = attempt!(bill_a, seq: 2, status: "expired")
    paid = attempt!(bill_b, status: "paid")

    result = void!(ctx)

    assert result.cancelled_attempt_ids == [pending.id]
    assert Repo.get!(PaymentAttempt, pending.id).status == "cancelled"
    assert Repo.get!(PaymentAttempt, expired.id).status == "expired"
    assert Repo.get!(PaymentAttempt, paid.id).status == "paid"
  end

  test "the reason is required and a refused void changes nothing", ctx do
    for reason <- [nil, "", "   "] do
      assert {:error, :reason_required} =
               Billing.void_issue(ctx.session.id, opts(ctx, reason: reason))
    end

    assert %Session{status: "issued"} = Repo.get!(Session, ctx.session.id)

    assert Repo.all(from b in Bill, select: b.status) |> Enum.sort() == [
             "paid",
             "unpaid",
             "unpaid"
           ]

    assert txn_count(ctx) == 1
    assert audit_rows(ctx, "session.void_issue") == []
  end

  test "only an issued session can be voided", ctx do
    void!(ctx)

    assert {:error, %TransitionError{entity: :session, from: "draft", trigger: :void_issue}} =
             Billing.void_issue(ctx.session.id, opts(ctx, reason: "lagi"))

    {:ok, _} = Billing.cancel_session(ctx.session.id)

    assert {:error, %TransitionError{from: "cancelled"}} =
             Billing.void_issue(ctx.session.id, opts(ctx, reason: "lagi"))

    assert {:error, :not_found} = Billing.void_issue(0, opts(ctx, reason: "lagi"))
  end

  test "a blank or missing key is refused", ctx do
    assert {:error, :idempotency_key_required} =
             Billing.void_issue(ctx.session.id, opts(ctx, reason: "x", idempotency_key: " "))

    assert {:error, :idempotency_key_required} =
             Billing.void_issue(ctx.session.id, actor: {:host, ctx.user.id}, reason: "x")
  end

  test "the same key again returns the same txn: one txn, one audit row", ctx do
    first = void!(ctx, idempotency_key: "void-1")
    again = void!(ctx, idempotency_key: "void-1")

    assert again.replayed == true
    assert again.txn.id == first.txn.id
    assert txn_count(ctx) == 2
    assert length(audit_rows(ctx, "session.void_issue")) == 1
  end

  test "a replay still answers after the session was issued again", ctx do
    first = void!(ctx, idempotency_key: "void-1")
    issue(ctx)

    assert %{replayed: true, txn: txn} = void!(ctx, idempotency_key: "void-1")
    assert txn.id == first.txn.id
    assert %Session{status: "issued"} = Repo.get!(Session, ctx.session.id)
    assert txn_count(ctx) == 3
  end

  test "a key used for a different void or another kind of txn is a conflict", ctx do
    void!(ctx, idempotency_key: "void-1")

    assert {:error, :idempotency_key_conflict} =
             Billing.void_issue(
               ctx.session.id,
               opts(ctx, reason: "alasan lain", idempotency_key: "void-1")
             )

    assert {:error, :idempotency_key_conflict} =
             Billing.void_issue(
               ctx.session.id,
               opts(ctx, reason: "x", idempotency_key: ctx.issue.txn |> key_of())
             )
  end

  defp key_of(%Txn{id: id}), do: Repo.get!(Txn, id).idempotency_key

  test "issue, partial gateway payment, void, issue again: the credit offsets the new bill",
       ctx do
    gateway_payment!(ctx, ctx.bills[ctx.a.id], 20_000)
    void!(ctx)

    assert {:ok, reissued} =
             Billing.issue(ctx.session.id,
               actor: {:host, ctx.user.id},
               idempotency_key: "issue-2"
             )

    bill = Enum.find(reissued.bills, &(&1.member_id == ctx.a.id))
    assert {bill.share, bill.credit_applied, bill.amount_due} == {34_000, 20_000, 14_000}
    assert bill.status == "unpaid"
    assert balance(ctx, ctx.a) == 20_000 - 34_000
  end
end
