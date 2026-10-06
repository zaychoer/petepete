defmodule Petepete.Payments.VoidIssueTest do
  use Petepete.DataCase, async: true
  use Oban.Testing, repo: Petepete.Repo

  alias Petepete.{BillingScenario, Payments}
  alias Petepete.Billing.Session
  alias Petepete.Payments.{CancelAttemptsJob, PaymentAttempt}

  setup do
    ctx = BillingScenario.issued()
    %{ctx: ctx, attempt: BillingScenario.attempt!(ctx.bills[ctx.a.id])}
  end

  test "the gateway cancellation job commits and rolls back together with the void", ctx do
    %{ctx: ctx, attempt: attempt} = ctx
    opts = BillingScenario.opts(ctx, reason: "salah hitung")

    assert {:error, :boom} =
             Repo.transaction(fn ->
               assert {:ok, %{cancelled_attempt_ids: [id]}} =
                        Payments.void_issue(ctx.session.id, opts)

               assert id == attempt.id
               Repo.rollback(:boom)
             end)

    refute_enqueued(worker: CancelAttemptsJob)
    assert Repo.get!(Session, ctx.session.id).status == "issued"
    assert Repo.get!(PaymentAttempt, attempt.id).status == "pending"

    assert {:ok, %{replayed: false}} = Payments.void_issue(ctx.session.id, opts)
    assert_enqueued(worker: CancelAttemptsJob, args: %{"attempt_ids" => [attempt.id]})
  end

  test "a replay of the same key enqueues nothing more, a failed void enqueues nothing", ctx do
    %{ctx: ctx} = ctx
    opts = BillingScenario.opts(ctx, reason: "salah hitung")

    assert {:ok, %{replayed: false}} = Payments.void_issue(ctx.session.id, opts)
    assert {:ok, %{replayed: true}} = Payments.void_issue(ctx.session.id, opts)
    assert [_one] = all_enqueued(worker: CancelAttemptsJob)

    # The session is a draft now: a second void under a new key is a transition error.
    assert {:error, %Petepete.Billing.TransitionError{}} =
             Payments.void_issue(ctx.session.id, BillingScenario.opts(ctx, reason: "lagi"))

    assert [_one] = all_enqueued(worker: CancelAttemptsJob)
  end
end
