defmodule Petepete.Payments.IntentReconciler do
  @moduledoc """
  Oban cron worker (`*/5 * * * *`) that sweeps stuck outbound intents.

  For each registered `OutboundIntent` kind module:

  1. `module.stuck(threshold)` — finds rows still pending/registering older than the threshold.
  2. `module.recover(row)` — decides the action (`:redrive`, `:fail`, `:needs_review`).
  3. Executes the action:
     - `:redrive` → `IntentRunner.redrive(module, row)`.
     - `:fail` → settles the row as failed and reports to Sentry.
     - `:needs_review` → settles the row as needs_review and reports to Sentry.
  """
  use Oban.Worker, queue: :payments, max_attempts: 1

  alias Petepete.Payments.IntentRunner
  alias Petepete.PhoneMask

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    threshold = stuck_threshold()

    for module <- intent_modules() do
      module.stuck(threshold)
      |> Enum.each(fn row -> handle_row(module, row) end)
    end

    :ok
  end

  defp handle_row(module, row) do
    case module.recover(row) do
      :redrive ->
        case IntentRunner.redrive(module, row) do
          {:ok, _settled} -> :ok
          {:error, _reason} -> report_exhausted(module, row)
        end

      :fail ->
        module.settle(row, {:error, :stuck_failed})
        report_stuck(module, row, :fail)

      :needs_review ->
        module.settle(row, {:error, :needs_review})
        report_stuck(module, row, :needs_review)
    end
  end

  defp report_stuck(module, row, action) do
    Sentry.capture_message(
      "IntentReconciler: #{action} for #{module.kind()}",
      extra: PhoneMask.scrub(%{id: row.id, kind: module.kind(), action: action})
    )
  end

  defp report_exhausted(module, row) do
    Sentry.capture_message(
      "IntentReconciler: redrive failed for #{module.kind()}",
      extra: PhoneMask.scrub(%{id: row.id, kind: module.kind(), retry_count: row.retry_count})
    )
  end

  defp stuck_threshold do
    seconds =
      :petepete
      |> Application.get_env(Petepete.Payments, [])
      |> Keyword.get(:intent_stuck_threshold_seconds, 600)

    DateTime.utc_now() |> DateTime.add(-seconds, :second)
  end

  defp intent_modules do
    :petepete
    |> Application.get_env(Petepete.Payments, [])
    |> Keyword.get(:intent_modules, [])
  end
end
