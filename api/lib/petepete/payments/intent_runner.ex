defmodule Petepete.Payments.IntentRunner do
  @moduledoc """
  Executes the prepare → request → settle steps of an `OutboundIntent` (ADR-0005).

  `run/2` wraps the full lifecycle in two transactions:

    1. `Repo.transaction` → `module.prepare(args)` – if the returned row is already
       settled (status not pending/registering), returns it immediately.
    2. `module.request(row, reference)` – outside any transaction.
    3. `Repo.transaction` → `module.settle(row, result)`.

  For callers that need to embed `prepare` inside their own transaction (e.g. HostAction),
  `prepare_only/2` and `complete/3` split the lifecycle: the caller runs `prepare_only`
  inside its transaction, commits, then calls `complete` with the row and reference.

  `redrive/2` re-drives a stuck row: request + settle only, incrementing `retry_count`.
  """
  alias Petepete.Repo

  @pending_statuses ~w(pending registering)

  @doc "Full lifecycle: prepare (in txn) → request → settle (in txn)."
  @spec run(module(), map()) :: {:ok, struct()} | {:error, term()}
  def run(module, args) do
    with {:ok, {row, reference}} <- do_prepare(module, args) do
      if row.status in @pending_statuses do
        complete(module, row, reference)
      else
        {:ok, row}
      end
    end
  end

  @doc "Prepare step only, inside the caller's existing transaction."
  @spec prepare_only(module(), map()) :: {:ok, row :: struct(), reference :: String.t()} | {:error, term()}
  def prepare_only(module, args), do: module.prepare(args)

  @doc "Request + settle steps, after prepare has committed."
  @spec complete(module(), struct(), String.t()) :: {:ok, struct()} | {:error, term()}
  def complete(module, row, reference) do
    result = module.request(row, reference)

    case Repo.transaction(fn -> module.settle(row, result) end) do
      {:ok, {:ok, settled}} -> {:ok, settled}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Re-drive a stuck row: increment retry_count, then request + settle."
  @spec redrive(module(), struct()) :: {:ok, struct()} | {:error, term()}
  def redrive(module, row) do
    reference = reference_for(module, row)

    row =
      row
      |> Ecto.Changeset.change(retry_count: row.retry_count + 1)
      |> Repo.update!()

    complete(module, row, reference)
  end

  defp do_prepare(module, args) do
    case Repo.transaction(fn -> module.prepare(args) end) do
      {:ok, {:ok, row, reference}} -> {:ok, {row, reference}}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reference_for(module, row) do
    case module.kind() do
      "payment_attempt" -> row.external_id
      "withdrawal" -> "withdrawal-#{row.id}"
      "payout_registration" -> "payout-reg-#{row.id}"
    end
  end
end
