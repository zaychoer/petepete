defmodule Petepete.Payments.IntentReconciler do
  @moduledoc """
  Oban cron job (every 5 minutes) that sweeps stuck outbound intents (ADR-0005).

  For each kind module, finds rows still pending/registering older than the threshold,
  asks the module what to do (`recover/1`), and acts:

    * `:redrive` – re-drives via `IntentRunner.redrive/2`; after `max_retries` the row
      is marked `failed` and reported to Sentry.
    * `:fail` – marks `failed` and reports to Sentry.
    * `:needs_review` – marks `needs_review` and reports to Sentry.
  """
  use Oban.Worker, queue: :payments, max_attempts: 1

  alias Petepete.Payments.IntentRunner
  alias Petepete.Payments.{PaymentAttemptIntent, WithdrawalIntent, PayoutRegistrationIntent}
  alias Petepete.Repo

  @kind_modules [PaymentAttemptIntent, WithdrawalIntent, PayoutRegistrationIntent]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    threshold = threshold()
    max_retries = max_retries()

    for module <- @kind_modules do
      module.stuck(threshold)
      |> Enum.each(fn row -> handle_stuck(module, row, max_retries) end)
    end

    :ok
  end

  defp handle_stuck(module, row, max_retries) do
    case module.recover(row) do
      :redrive ->
        if row.retry_count >= max_retries do
          mark_failed(row)
          report("#{module.kind()}_exhausted_retries", row)
        else
          case IntentRunner.redrive(module, row) do
            {:ok, _} -> :ok
            {:error, _} -> :ok
          end
        end

      :fail ->
        mark_failed(row)
        report("#{module.kind()}_stuck_failed", row)

      :needs_review ->
        mark_needs_review(row)
        report("#{module.kind()}_needs_review", row)
    end
  end

  defp mark_failed(row) do
    row |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
  end

  defp mark_needs_review(row) do
    row |> Ecto.Changeset.change(status: "needs_review") |> Repo.update!()
  end

  defp report(message, row) do
    Sentry.capture_message(message,
      extra: %{
        id: row.id,
        kind: row.__struct__,
        retry_count: row.retry_count
      }
    )
  end

  defp threshold do
    seconds =
      :petepete
      |> Application.get_env(Petepete.Payments, [])
      |> Keyword.get(:intent_stuck_threshold_seconds, 600)

    DateTime.add(DateTime.utc_now(:second), -seconds, :second)
  end

  defp max_retries do
    :petepete
    |> Application.get_env(Petepete.Payments, [])
    |> Keyword.get(:intent_max_retries, 3)
  end
end
