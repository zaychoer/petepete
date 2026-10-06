defmodule Petepete.Billing.Replay do
  @moduledoc """
  Idempotent-replay helpers shared by the Billing commands that post a money event
  (`void_issue`, `mark_paid_cash`, `cancel_cash`).

  A command calls `find/4` after taking its row locks and before it checks any status
  rule: the first request already moved the state (the session is draft again, the bill is
  paid), so only the txn the key posted can tell a repeat from a new request. A repeat is
  then handed to `Ledger.record/2`, which verifies it is the same event and answers with
  the original txn (`replayed: true`) without posting.
  """

  alias Petepete.Ledger.Txn
  alias Petepete.Repo

  @doc "A blank or missing `Idempotency-Key` is refused before anything is read."
  @spec require_key(term()) :: :ok | {:error, :idempotency_key_required}
  def require_key(key) when is_binary(key) do
    if String.trim(key) == "", do: {:error, :idempotency_key_required}, else: :ok
  end

  def require_key(_key), do: {:error, :idempotency_key_required}

  @doc """
  The txn already posted under `key`, if any.

  `{:ok, txn}` when it is a `kind` txn about `{ref_type, ref_id}` (the same request again);
  `{:error, :idempotency_key_conflict}` when the key was used for anything else; `nil` when
  the key is new.
  """
  @spec find(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, %Txn{}} | {:error, :idempotency_key_conflict} | nil
  def find(key, kind, ref_type, ref_id) do
    case Repo.get_by(Txn, idempotency_key: key) do
      nil ->
        nil

      %Txn{kind: ^kind, ref_type: ^ref_type, ref_id: ^ref_id} = txn ->
        {:ok, txn}

      %Txn{} ->
        {:error, :idempotency_key_conflict}
    end
  end
end
