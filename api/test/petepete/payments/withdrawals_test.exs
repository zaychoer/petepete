defmodule Petepete.Payments.WithdrawalsTest do
  # Not async: the fake gateway's behaviour is application config.
  use Petepete.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Petepete.{BillingScenario, FakeGateway, Payments}
  alias Petepete.Ledger.AuditLog
  alias Petepete.Payments.Gateway.Spy
  alias Petepete.Payments.Withdrawal

  setup do
    FakeGateway.configure(balance: 500_000, notify: self())
    ctx = BillingScenario.issued()
    %{ctx: ctx}
  end

  defp withdraw(ctx, key, amount),
    do: Payments.withdraw(ctx.group.id, ctx.host, ctx.user.id, key, amount)

  defp audit_actions,
    do:
      Repo.all(
        from a in AuditLog,
          where: like(a.action, "withdrawal.%"),
          order_by: a.id,
          select: a.action
      )

  test "the request is committed pending, with its audit row, before the gateway is asked",
       %{ctx: ctx} do
    test = self()

    Spy.install(fn :withdraw, reference ->
      send(test, {:seen_at_call, reference, Repo.all(Withdrawal), audit_actions()})
    end)

    assert {:ok, %{withdrawal: w, replayed: false}} = withdraw(ctx, "k1", 200_000)

    assert_received {:seen_at_call, reference,
                     [%Withdrawal{status: "pending", provider_ref: nil}], ["withdrawal.request"]}

    assert reference == "withdrawal-#{w.id}"
    assert w.status == "submitted" and w.provider_ref =~ reference
    assert audit_actions() == ["withdrawal.request", "withdrawal.submitted"]
  end

  test "a request the gateway accepted is never sent again", %{ctx: ctx} do
    assert {:ok, %{withdrawal: first, replayed: false}} = withdraw(ctx, "k1", 100_000)
    assert_received {:fake_gateway, :withdraw, _}

    assert {:ok, %{withdrawal: again, replayed: true}} = withdraw(ctx, "k1", 100_000)
    assert again.id == first.id
    refute_received {:fake_gateway, :withdraw, _}

    assert {:error, :idempotency_key_conflict} = withdraw(ctx, "k1", 150_000)
    assert Repo.aggregate(Withdrawal, :count) == 1
  end

  test "a refused request is kept as failed and the same key tries again", %{ctx: ctx} do
    FakeGateway.configure(withdraw: {:error, :provider_down})
    assert {:error, {:gateway_error, :provider_down}} = withdraw(ctx, "k1", 100_000)

    assert [%Withdrawal{id: id, status: "failed", provider_ref: nil}] = Repo.all(Withdrawal)
    assert_received {:fake_gateway, :withdraw, reference}
    assert reference == "withdrawal-#{id}"

    assert {:error, :idempotency_key_conflict} = withdraw(ctx, "k1", 120_000)

    FakeGateway.configure(withdraw: :api)
    assert {:ok, %{withdrawal: retried, replayed: true}} = withdraw(ctx, "k1", 100_000)

    assert retried.id == id and retried.status == "submitted"
    assert Repo.aggregate(Withdrawal, :count) == 1
    assert_received {:fake_gateway, :withdraw, ^reference}

    assert audit_actions() ==
             ~w(withdrawal.request withdrawal.failed withdrawal.request withdrawal.submitted)
  end

  test "a request left pending by a crash is returned, not sent again, and holds its amount",
       %{ctx: ctx} do
    stuck =
      Repo.insert!(%Withdrawal{
        group_id: ctx.group.id,
        payout_account_id: ctx.payout_account.id,
        amount: 400_000,
        status: "pending",
        idempotency_key: "crashed"
      })

    assert {:ok, %{withdrawal: same, replayed: true}} = withdraw(ctx, "crashed", 400_000)
    assert same.id == stuck.id and same.status == "pending"
    refute_received {:fake_gateway, :withdraw, _}

    # 500_000 at the gateway, 400_000 of it already spoken for.
    assert {:error, :insufficient_balance} = withdraw(ctx, "other", 200_000)
    assert {:ok, %{withdrawal: %{status: "submitted"}}} = withdraw(ctx, "other", 100_000)
  end
end
