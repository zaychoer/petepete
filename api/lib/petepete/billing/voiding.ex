defmodule Petepete.Billing.Voiding do
  @moduledoc """
  `Billing.void_issue/2` (Batalkan tagihan): takes an issued or settled session back to
  draft so its costs and attendance can be edited and the bills issued again.

  One transaction, in the spec's lock order: the session row, the session's bill rows by id
  (`Petepete.Billing.Locks.lock_session_and_bills/1`), then the Ledger group lock inside
  `Ledger.record/2`. Inside it:

    1. `Ledger.record/2` posts `SessionBillsCancelled` against the session's issue txn. The
       reason is required. It is not checked against the kas balance, so kas may go negative.
    2. Every bill of the session that is not void yet becomes `void`
       (`Petepete.Billing.Transitions.void_bill/1`). Money already paid stays in the ledger,
       so it is the participant's credit; issuing again consumes it.
    3. The pending payment attempts of those bills become `cancelled` (status only). Telling
       the gateway to drop them is the payment side's job, so their ids are returned in
       `cancelled_attempt_ids`; `Petepete.Payments.void_issue/2` runs this function in its
       own transaction and inserts `Petepete.Payments.CancelAttemptsJob` for them before the
       commit. This function joins a caller's transaction.
    4. The session moves issued -> draft (`Transitions.revert_session_to_draft/1`); its
       `issue_txn_id` is left as is until the next issue overwrites it.
    5. `Petepete.Ledger.Audit.record/5` writes `session.void_issue` (subject: the new txn).

  The same `Idempotency-Key` again returns the txn the first request posted with
  `replayed: true` and changes nothing, including after the session was issued again.
  A payment that still reaches a void bill is posted as credit by
  `Billing.apply_gateway_payment/2`.
  """

  alias Petepete.Billing.{Locks, Replay, Transitions}
  alias Petepete.Actor
  alias Petepete.Ledger
  alias Petepete.Ledger.Audit
  alias Petepete.Ledger.Event.SessionBillsCancelled
  alias Petepete.Payments.PaymentAttempt
  alias Petepete.Repo

  import Ecto.Query, only: [from: 2]

  @doc "See `Petepete.Billing.void_issue/2`."
  @spec void_issue(pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def void_issue(session_id, opts) when is_integer(session_id) do
    %Actor{type: :host} = actor = Keyword.fetch!(opts, :actor)
    key = Keyword.get(opts, :idempotency_key)
    reason = Keyword.get(opts, :reason)

    with :ok <- Replay.require_key(key) do
      Repo.transaction(fn ->
        with {:ok, session, bills} <- Locks.lock_session_and_bills(session_id),
             {:ok, reply} <- void_locked(session, bills, actor, key, reason) do
          reply
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp void_locked(session, bills, actor, key, reason) do
    case Replay.find(key, "session_bills_cancelled", "session", session.id) do
      {:ok, txn} -> replay(session, txn, actor, key, reason)
      {:error, _} = error -> error
      nil -> post(session, bills, actor, key, reason)
    end
  end

  defp post(session, bills, actor, key, reason) do
    with :ok <- Transitions.session(session.status, "draft", :void_issue),
         {:ok, %{txn: txn}} <-
           Ledger.record(actor, event(session, session.issue_txn_id, key, reason)),
         live = Enum.reject(bills, &(&1.status == "void")),
         {:ok, voided} <- void_bills(live),
         attempt_ids = cancel_pending_attempts(voided),
         {:ok, draft} <- Transitions.revert_session_to_draft(session) do
      bill_ids = Enum.map(voided, & &1.id)

      Audit.record(session.group_id, actor.user_id, "session.void_issue", {"txn", txn.id}, %{
        "session_id" => session.id,
        "reason" => reason,
        "voided_bill_ids" => bill_ids,
        "cancelled_attempt_ids" => attempt_ids
      })

      {:ok,
       %{
         session: draft,
         txn: txn,
         voided_bill_ids: bill_ids,
         cancelled_attempt_ids: attempt_ids,
         replayed: false
       }}
    end
  end

  # The session may be issued again by now, so the original txn comes from the stored one.
  defp replay(session, txn, actor, key, reason) do
    case Ledger.record(actor, event(session, txn.reverses_txn_id, key, reason)) do
      {:ok, %{txn: replayed_txn, replayed: true}} ->
        {:ok,
         %{
           session: session,
           txn: replayed_txn,
           voided_bill_ids: [],
           cancelled_attempt_ids: [],
           replayed: true
         }}

      {:error, _} = error ->
        error
    end
  end

  defp event(session, issue_txn_id, key, reason) do
    %SessionBillsCancelled{
      idempotency_key: key,
      group_id: session.group_id,
      txn_id: issue_txn_id,
      reason: reason
    }
  end

  defp void_bills(bills) do
    Enum.reduce_while(bills, {:ok, []}, fn bill, {:ok, acc} ->
      case Transitions.void_bill(bill) do
        {:ok, voided} -> {:cont, {:ok, [voided | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, voided} -> {:ok, Enum.reverse(voided)}
      error -> error
    end
  end

  defp cancel_pending_attempts(voided_bills) do
    bill_ids = Enum.map(voided_bills, & &1.id)

    {_, ids} =
      Repo.update_all(
        from(a in PaymentAttempt,
          where: a.bill_id in ^bill_ids and a.status == "pending",
          select: a.id
        ),
        set: [status: "cancelled", updated_at: DateTime.utc_now(:second)]
      )

    Enum.sort(ids)
  end
end
