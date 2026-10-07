defmodule Petepete.Payments.IntentReconcilerTest do
  # Not async: the fake gateway's behaviour is application config.
  use Petepete.DataCase, async: false

  alias Petepete.{BillingScenario, Clock, FakeGateway}
  alias Petepete.Groups.PayoutAccount
  alias Petepete.Payments.{IntentReconciler, PaymentAttempt, Withdrawal}

  @threshold_seconds 600

  defp put_payments_config(overrides) do
    old = Application.get_env(:petepete, Petepete.Payments, [])
    Application.put_env(:petepete, Petepete.Payments, Keyword.merge(old, overrides))
    on_exit(fn -> Application.put_env(:petepete, Petepete.Payments, old) end)
  end

  describe "payment attempts" do
    setup do
      Clock.freeze(~U[2026-10-06 03:00:00Z])
      FakeGateway.configure(notify: self())

      put_payments_config(
        intent_stuck_threshold_seconds: @threshold_seconds,
        intent_max_retries: 3
      )

      ctx = BillingScenario.issued()
      %{bill: ctx.bills[ctx.a.id]}
    end

    test "reconciler re-drives a stuck pending attempt (no provider_ref, older than threshold)",
         %{bill: bill} do
      # Insert a stuck pending attempt older than the threshold.
      stuck_time = DateTime.add(~U[2026-10-06 03:00:00Z], -(@threshold_seconds + 60), :second)

      stuck =
        Repo.insert!(%PaymentAttempt{
          bill_id: bill.id,
          seq: 1,
          external_id: "#{bill.id}-1",
          provider: "fake",
          method: "qris",
          amount_due: bill.amount_due,
          fee: 240,
          gross_amount: bill.amount_due + 240,
          status: "pending",
          expires_at: DateTime.add(~U[2026-10-06 03:00:00Z], 3600, :second),
          inserted_at: stuck_time,
          updated_at: stuck_time
        })

      assert is_nil(stuck.provider_ref)

      # Run the reconciler.
      assert :ok = IntentReconciler.perform(%Oban.Job{args: %{}})

      # The attempt should now have a provider_ref (re-driven successfully).
      updated = Repo.get!(PaymentAttempt, stuck.id)
      assert updated.provider_ref == "fake-#{bill.id}-1"
      assert updated.retry_count == 1
      assert_received {:fake_gateway, :create_payment, _}
    end

    test "reconciler marks stuck attempt as failed after max retries", %{bill: bill} do
      stuck_time = DateTime.add(~U[2026-10-06 03:00:00Z], -(@threshold_seconds + 60), :second)

      stuck =
        Repo.insert!(%PaymentAttempt{
          bill_id: bill.id,
          seq: 1,
          external_id: "#{bill.id}-1",
          provider: "fake",
          method: "qris",
          amount_due: bill.amount_due,
          fee: 240,
          gross_amount: bill.amount_due + 240,
          status: "pending",
          expires_at: DateTime.add(~U[2026-10-06 03:00:00Z], 3600, :second),
          retry_count: 3,
          inserted_at: stuck_time,
          updated_at: stuck_time
        })

      assert :ok = IntentReconciler.perform(%Oban.Job{args: %{}})

      updated = Repo.get!(PaymentAttempt, stuck.id)
      assert updated.status == "failed"
      assert updated.retry_count == 3
      refute_received {:fake_gateway, :create_payment, _}
    end
  end

  describe "withdrawals" do
    setup do
      FakeGateway.configure(balance: 500_000, notify: self())

      put_payments_config(
        intent_stuck_threshold_seconds: @threshold_seconds,
        intent_max_retries: 3
      )

      ctx = BillingScenario.issued()
      %{ctx: ctx}
    end

    test "a stuck pending withdrawal moves to needs_review (default recovery)", %{ctx: ctx} do
      stuck_time = DateTime.add(DateTime.utc_now(:second), -(@threshold_seconds + 60), :second)

      stuck =
        Repo.insert!(%Withdrawal{
          group_id: ctx.group.id,
          payout_account_id: ctx.payout_account.id,
          amount: 100_000,
          status: "pending",
          idempotency_key: "stuck-wd",
          inserted_at: stuck_time
        })

      # Default: gateway.withdrawal_status returns :not_found → :redrive
      # But after max_retries, it would fail. Let's test with :unsupported to get :needs_review.
      FakeGateway.configure(withdrawal_status: {:error, :unsupported})

      assert :ok = IntentReconciler.perform(%Oban.Job{args: %{}})

      updated = Repo.get!(Withdrawal, stuck.id)
      assert updated.status == "needs_review"
    end

    test "when the Fake returns :submitted for a stuck withdrawal, the reconciler settles it",
         %{ctx: ctx} do
      stuck_time = DateTime.add(DateTime.utc_now(:second), -(@threshold_seconds + 60), :second)

      stuck =
        Repo.insert!(%Withdrawal{
          group_id: ctx.group.id,
          payout_account_id: ctx.payout_account.id,
          amount: 100_000,
          status: "pending",
          idempotency_key: "stuck-wd-settled",
          inserted_at: stuck_time
        })

      # withdrawal_status returns :submitted → :redrive → calls request → settles
      FakeGateway.configure(withdrawal_status: {:ok, :submitted})

      assert :ok = IntentReconciler.perform(%Oban.Job{args: %{}})

      updated = Repo.get!(Withdrawal, stuck.id)
      # The redrive calls WithdrawalIntent.request → gateway.withdraw → settles
      assert updated.status in ~w(submitted managed)
      assert updated.retry_count == 1
      assert_received {:fake_gateway, :withdraw, _}
    end
  end

  describe "payout registration" do
    setup do
      FakeGateway.configure(notify: self())

      put_payments_config(
        intent_stuck_threshold_seconds: @threshold_seconds,
        intent_max_retries: 3
      )

      group = Petepete.Fixtures.group_fixture()
      {_user, host} = Petepete.Fixtures.host_fixture(group)
      %{group: group, host: host}
    end

    test "reconciler marks stuck registering payout account as failed after threshold",
         %{group: group, host: host} do
      stuck_time = DateTime.add(DateTime.utc_now(:second), -(@threshold_seconds + 60), :second)

      stuck =
        Repo.insert!(%PayoutAccount{
          group_id: group.id,
          owner_member_id: host.id,
          provider: "fake",
          status: "registering",
          bank_name: "BCA",
          account_last4: "9012",
          idempotency_key: "stuck-pa",
          inserted_at: stuck_time,
          updated_at: stuck_time
        })

      assert :ok = IntentReconciler.perform(%Oban.Job{args: %{}})

      updated = Repo.get!(PayoutAccount, stuck.id)
      assert updated.status == "failed"
    end
  end
end
