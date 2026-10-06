defmodule Petepete.Ledger.HostActions do
  @moduledoc """
  The host's own ledger entries: Catat pelunasan antar anggota (`Settlement`), Belanja
  kas (`KasSpend`) and Koreksi (`Correction`).

  Three thin host actions on top of `Petepete.HostAction.run/4`: each posts one event with
  `Petepete.Ledger.record/2` and lets the wrapper own the transaction and the `audit_log`
  row (written once, skipped for an idempotent replay, rolled back with the Ledger on
  error). The caller passes a host `Petepete.Actor` from `Petepete.Groups.authorize_actor/3`;
  no role is checked here. They answer `{:ok, %{txn: txn, replayed: boolean}}` or
  `{:error, reason}` with the Ledger's reasons.
  """
  alias Petepete.{Actor, HostAction, Ledger}
  alias Petepete.Ledger.Event.{Correction, KasSpend, Settlement}

  @type result :: {:ok, %{txn: Ledger.Txn.t(), replayed: boolean()}} | {:error, atom()}

  @doc "`params`: `payer_member_id`, `payee_member_id`, `amount`, `note`."
  @spec record_settlement(Actor.t(), pos_integer(), String.t(), map()) :: result()
  def record_settlement(%Actor{} = actor, group_id, key, params) do
    event = %Settlement{
      idempotency_key: key,
      group_id: group_id,
      payer_member_id: params.payer_member_id,
      payee_member_id: params.payee_member_id,
      amount: params.amount,
      note: params[:note]
    }

    post(actor, group_id, event, "settlement.record", %{
      "payer_member_id" => params.payer_member_id,
      "payee_member_id" => params.payee_member_id,
      "amount" => params.amount,
      "note" => params[:note]
    })
  end

  @doc "`params`: `member_id`, `amount`, `note`."
  @spec record_kas_spend(Actor.t(), pos_integer(), String.t(), map()) :: result()
  def record_kas_spend(%Actor{} = actor, group_id, key, params) do
    event = %KasSpend{
      idempotency_key: key,
      group_id: group_id,
      member_id: params.member_id,
      amount: params.amount,
      note: params[:note]
    }

    post(actor, group_id, event, "kas_spend.record", %{
      "member_id" => params.member_id,
      "amount" => params.amount,
      "note" => params[:note]
    })
  end

  @doc "Reverses a settlement or kas spend txn. The Ledger rejects every other kind."
  @spec correct(Actor.t(), pos_integer(), String.t(), pos_integer(), String.t() | nil) ::
          result()
  def correct(%Actor{} = actor, group_id, key, txn_id, reason) do
    event = %Correction{
      idempotency_key: key,
      group_id: group_id,
      txn_id: txn_id,
      reason: reason
    }

    post(actor, group_id, event, "txn.correct", %{"original_txn_id" => txn_id, "reason" => reason})
  end

  defp post(actor, group_id, event, action, metadata) do
    HostAction.run(actor, group_id, action, fn ->
      with {:ok, %{txn: txn, replayed: replayed} = res} <- Ledger.record(actor, event) do
        {:ok, Map.take(res, [:txn, :replayed]),
         %{subject: {"txn", txn.id}, metadata: metadata, replayed: replayed}}
      end
    end)
  end
end
