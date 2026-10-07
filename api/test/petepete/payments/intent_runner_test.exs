defmodule Petepete.Payments.IntentRunnerTest do
  use Petepete.DataCase, async: false

  alias Petepete.Payments.IntentRunner
  alias Petepete.TestIntent

  # We need a bill for the payment_attempts FK
  setup do
    ctx = Petepete.BillingScenario.issued()
    bill = ctx.bills |> Map.values() |> hd()
    TestIntent.start(bill_id: bill.id)
    on_exit(fn -> TestIntent.stop() end)
    %{bill_id: bill.id}
  end

  describe "run/2" do
    test "success: prepare → request → settle", %{bill_id: bill_id} do
      ref = "run-success-#{System.unique_integer([:positive])}"

      assert {:ok, settled} =
               IntentRunner.run(TestIntent, %{ref: ref, bill_id: bill_id})

      assert settled.status == "paid"
      assert settled.external_id == ref
    end

    test "replay: already settled row is returned without calling request again", %{
      bill_id: bill_id
    } do
      ref = "run-replay-#{System.unique_integer([:positive])}"

      # First run succeeds
      {:ok, first} = IntentRunner.run(TestIntent, %{ref: ref, bill_id: bill_id})
      assert first.status == "paid"

      # Second run with same ref replays — prepare returns the settled row, runner skips request
      {:ok, replayed} = IntentRunner.run(TestIntent, %{ref: ref, bill_id: bill_id})
      assert replayed.id == first.id
      assert replayed.status == "paid"
    end

    test "request failure → settle with error", %{bill_id: bill_id} do
      TestIntent.configure(request_result: {:error, :gateway_down})
      ref = "run-fail-#{System.unique_integer([:positive])}"

      assert {:ok, settled} =
               IntentRunner.run(TestIntent, %{ref: ref, bill_id: bill_id})

      assert settled.status == "failed"
    end
  end

  describe "prepare_only/2 + complete/3" do
    test "two-step flow for HostAction callers", %{bill_id: bill_id} do
      ref = "two-step-#{System.unique_integer([:positive])}"

      assert {:ok, row, ^ref} =
               IntentRunner.prepare_only(TestIntent, %{ref: ref, bill_id: bill_id})

      assert row.status == "pending"

      assert {:ok, settled} = IntentRunner.complete(TestIntent, row, ref)
      assert settled.status == "paid"
    end
  end

  describe "redrive/2" do
    test "increments retry_count and settles", %{bill_id: bill_id} do
      ref = "redrive-#{System.unique_integer([:positive])}"
      {:ok, row} = IntentRunner.run(TestIntent, %{ref: ref, bill_id: bill_id})

      # Reset status to pending to simulate stuck row
      row
      |> Ecto.Changeset.change(status: "pending")
      |> Repo.update!()

      row = %{row | status: "pending", retry_count: 0}

      assert {:ok, settled} = IntentRunner.redrive(TestIntent, row)
      assert settled.retry_count == 1
      assert settled.status == "paid"
    end

    test "after max retries → :fail", %{bill_id: bill_id} do
      ref = "redrive-max-#{System.unique_integer([:positive])}"
      {:ok, row} = IntentRunner.run(TestIntent, %{ref: ref, bill_id: bill_id})

      # Set retry_count to max (3) so next redrive exceeds it
      row
      |> Ecto.Changeset.change(status: "pending", retry_count: 3)
      |> Repo.update!()

      row = %{row | status: "pending", retry_count: 3}

      assert {:ok, settled} = IntentRunner.redrive(TestIntent, row)
      assert settled.status == "failed"
      # retry_count is incremented to 4 (> max of 3)
      assert settled.retry_count == 4
    end
  end
end
