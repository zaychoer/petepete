defmodule Petepete.Payments.IntentRunner do
  @moduledoc """
  Drives the prepare → request → settle sequence for any `OutboundIntent` kind.

  ## Simple callers

      IntentRunner.run(PaymentAttemptIntent, %{bill_id: id, method: "qris"})

  ## HostAction callers

  When the caller's first transaction is owned by `HostAction`, use the two-step
  API so `prepare` runs inside that transaction and `request + settle` run after commit:

      {:ok, row, ref} = IntentRunner.prepare_only(WithdrawalIntent, args)
      # ... HostAction commits ...
      IntentRunner.complete(WithdrawalIntent, row, ref)

  ## Reconciler

      IntentRunner.redrive(module, row)
  """

  alias Petepete.Repo

  @doc """
  Runs the full prepare → request → settle sequence.

  1. `Repo.transaction` → `module.prepare(args)` — if the row is already settled, returns it.
  2. `module.request(row, reference)` — outside any transaction.
  3. `Repo.transaction` → `module.settle(row, result)`.
  """
  @spec run(module(), map()) :: {:ok, struct()} | {:error, term()}
  def run(module, args) do
    with {:ok, {row, ref}} <- prepare_tx(module, args) do
      if settled?(row) do
        {:ok, row}
      else
        request_and_settle(module, row, ref)
      end
    end
  end

  @doc """
  Runs only `prepare` inside a `Repo.transaction`, returning the row and reference
  for `complete/3`. The caller embeds this in its own transaction (e.g. HostAction).
  """
  @spec prepare_only(module(), map()) :: {:ok, struct(), String.t()} | {:error, term()}
  def prepare_only(module, args) do
    case module.prepare(args) do
      {:ok, row, ref} -> {:ok, row, ref}
      {:error, _} = err -> err
    end
  end

  @doc """
  Runs request + settle for a previously prepared row. Called after the caller's
  transaction commits.
  """
  @spec complete(module(), struct(), String.t()) :: {:ok, struct()} | {:error, term()}
  def complete(module, row, ref) do
    if settled?(row) do
      {:ok, row}
    else
      request_and_settle(module, row, ref)
    end
  end

  @doc """
  Re-drives a stuck row: calls request + settle and increments `retry_count`.
  Returns `{:ok, settled}` or `{:error, reason}`.
  After `max_retries` the row is settled with `{:error, :max_retries_exceeded}`.
  """
  @spec redrive(module(), struct()) :: {:ok, struct()} | {:error, term()}
  def redrive(module, row) do
    max = intent_max_retries()
    row = increment_retry_count(row)

    if row.retry_count > max do
      settle_tx(module, row, {:error, :max_retries_exceeded})
    else
      ref = reference_from_row(module, row)
      request_and_settle(module, row, ref)
    end
  end

  # -- private --

  defp prepare_tx(module, args) do
    Repo.transaction(fn ->
      case module.prepare(args) do
        {:ok, row, ref} -> {row, ref}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp request_and_settle(module, row, ref) do
    result = module.request(row, ref)
    settle_tx(module, row, result)
  end

  defp settle_tx(module, row, result) do
    Repo.transaction(fn ->
      case module.settle(row, result) do
        {:ok, settled} -> settled
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp settled?(%{status: status})
       when status in ~w(submitted managed active failed needs_review paid expired cancelled),
       do: true

  defp settled?(_row), do: false

  defp increment_retry_count(%{retry_count: count} = row) do
    new_count = (count || 0) + 1

    row.__struct__
    |> Repo.get!(row.id)
    |> Ecto.Changeset.change(retry_count: new_count)
    |> Repo.update!()
  end

  defp reference_from_row(module, row) do
    # The kind module knows how to derive the reference from the row.
    # Convention: the row has an `external_id` or `idempotency_key` field.
    cond do
      function_exported?(module, :reference_from_row, 1) -> module.reference_from_row(row)
      Map.has_key?(row, :external_id) -> row.external_id
      Map.has_key?(row, :idempotency_key) -> row.idempotency_key
      true -> raise "Cannot derive reference from #{inspect(row.__struct__)}"
    end
  end

  defp intent_max_retries do
    :petepete
    |> Application.get_env(Petepete.Payments, [])
    |> Keyword.get(:intent_max_retries, 3)
  end
end
