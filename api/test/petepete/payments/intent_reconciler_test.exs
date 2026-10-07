defmodule Petepete.Payments.IntentReconcilerTest do
  use Petepete.DataCase, async: false
  use Oban.Testing, repo: Petepete.Repo

  alias Petepete.Payments.{IntentReconciler, IntentRunner}
  alias Petepete.TestIntent

  setup do
    ctx = Petepete.BillingScenario.issued()
    bill = ctx.bills |> Map.values() |> hd()
    TestIntent.start(bill_id: bill.id)
    on_exit(fn -> TestIntent.stop() end)

    # Register the test intent module
    original = Application.get_env(:petepete, Petepete.Payments, [])

    Application.put_env(
      :petepete,
      Petepete.Payments,
      Keyword.merge(original, intent_modules: [TestIntent])
    )

    on_exit(fn -> Application.put_env(:petepete, Petepete.Payments, original) end)

    %{bill_id: bill.id}
  end

  test "reconciler redrives stuck rows", %{bill_id: bill_id} do
    ref = "recon-redrive-#{System.unique_integer([:positive])}"
    {:ok, row} = IntentRunner.run(TestIntent, %{ref: ref, bill_id: bill_id})

    # Make the row look stuck (pending)
    row
    |> Ecto.Changeset.change(status: "pending")
    |> Repo.update!()

    stuck_row = %{row | status: "pending"}

    # Configure test intent: stuck returns our row, recover says :redrive
    TestIntent.configure(stuck_rows: [stuck_row], recover_action: :redrive)

    assert :ok = perform_job(IntentReconciler, %{})

    # Row should be settled after redrive
    updated = Repo.get!(TestIntent, row.id)
    assert updated.status == "paid"
    assert updated.retry_count == 1
  end

  test "reconciler marks :fail rows as failed", %{bill_id: bill_id} do
    ref = "recon-fail-#{System.unique_integer([:positive])}"
    {:ok, row} = IntentRunner.run(TestIntent, %{ref: ref, bill_id: bill_id})

    row
    |> Ecto.Changeset.change(status: "pending")
    |> Repo.update!()

    stuck_row = %{row | status: "pending"}
    TestIntent.configure(stuck_rows: [stuck_row], recover_action: :fail)

    assert :ok = perform_job(IntentReconciler, %{})

    updated = Repo.get!(TestIntent, row.id)
    assert updated.status == "failed"
  end

  test "reconciler marks :needs_review rows", %{bill_id: bill_id} do
    ref = "recon-review-#{System.unique_integer([:positive])}"
    {:ok, row} = IntentRunner.run(TestIntent, %{ref: ref, bill_id: bill_id})

    row
    |> Ecto.Changeset.change(status: "pending")
    |> Repo.update!()

    stuck_row = %{row | status: "pending"}
    TestIntent.configure(stuck_rows: [stuck_row], recover_action: :needs_review)

    assert :ok = perform_job(IntentReconciler, %{})

    updated = Repo.get!(TestIntent, row.id)
    assert updated.status == "expired"
  end
end
