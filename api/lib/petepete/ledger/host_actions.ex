defmodule Petepete.Ledger.HostActions do
  @moduledoc """
  The host's own ledger entries: Catat pelunasan antar anggota (`Settlement`), Belanja
  kas (`KasSpend`) and Koreksi (`Correction`).

  Each function opens one transaction that holds the Ledger post and its `audit_log` row
  (`Petepete.Ledger.Audit`). An error from the Ledger rolls everything back. An idempotent
  replay returns the original txn with `replayed: true` and writes no second audit row.
  Callers must already have authorized `host_user_id` as host of the group.
  """
  alias Petepete.Ledger
  alias Petepete.Ledger.Audit
  alias Petepete.Ledger.Event.{Correction, KasSpend, Settlement}
  alias Petepete.Repo

  @type result :: {:ok, %{txn: Ledger.Txn.t(), replayed: boolean()}} | {:error, atom()}

  @doc "`params`: `payer_member_id`, `payee_member_id`, `amount`, `note`."
  @spec record_settlement(pos_integer(), pos_integer(), String.t(), map()) :: result()
  def record_settlement(group_id, host_user_id, key, params) do
    event = %Settlement{
      idempotency_key: key,
      group_id: group_id,
      payer_member_id: params.payer_member_id,
      payee_member_id: params.payee_member_id,
      amount: params.amount,
      note: params[:note]
    }

    post(group_id, host_user_id, event, "settlement.record", fn _txn ->
      %{
        "payer_member_id" => params.payer_member_id,
        "payee_member_id" => params.payee_member_id,
        "amount" => params.amount,
        "note" => params[:note]
      }
    end)
  end

  @doc "`params`: `member_id`, `amount`, `note`."
  @spec record_kas_spend(pos_integer(), pos_integer(), String.t(), map()) :: result()
  def record_kas_spend(group_id, host_user_id, key, params) do
    event = %KasSpend{
      idempotency_key: key,
      group_id: group_id,
      member_id: params.member_id,
      amount: params.amount,
      note: params[:note]
    }

    post(group_id, host_user_id, event, "kas_spend.record", fn _txn ->
      %{
        "member_id" => params.member_id,
        "amount" => params.amount,
        "note" => params[:note]
      }
    end)
  end

  @doc "Reverses a settlement or kas spend txn. The Ledger rejects every other kind."
  @spec correct(pos_integer(), pos_integer(), String.t(), pos_integer(), String.t() | nil) ::
          result()
  def correct(group_id, host_user_id, key, txn_id, reason) do
    event = %Correction{
      idempotency_key: key,
      group_id: group_id,
      txn_id: txn_id,
      reason: reason
    }

    post(group_id, host_user_id, event, "txn.correct", fn _txn ->
      %{"original_txn_id" => txn_id, "reason" => reason}
    end)
  end

  defp post(group_id, host_user_id, event, action, metadata) do
    outcome =
      Repo.transaction(fn ->
        case Ledger.record({:host, host_user_id}, event) do
          {:ok, %{replayed: true} = res} ->
            res

          {:ok, %{txn: txn} = res} ->
            Audit.record(group_id, host_user_id, action, {"txn", txn.id}, metadata.(txn))
            res

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case outcome do
      {:ok, res} -> {:ok, Map.take(res, [:txn, :replayed])}
      {:error, reason} -> {:error, reason}
    end
  end
end
