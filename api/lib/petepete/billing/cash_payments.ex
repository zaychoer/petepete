defmodule Petepete.Billing.CashPayments do
  @moduledoc """
  `Billing.mark_paid_cash/2` (Tandai lunas) and `Billing.cancel_cash/2` (Batal cash): the
  host takes a bill's money in cash, or undoes that within 24 hours.

  Both lock only the bill row, then the Ledger group lock inside `Ledger.record/2`; they
  never touch the session row (its Selesai status is derived from the bills, so it flips
  by itself). Each is a host action (`Petepete.HostAction.run/4`): one transaction holding
  the ledger post, the bill transition and the `audit_log` row, which a replay does not write.

  `mark_paid_cash` accepts an `unpaid` or `needs_review` bill and posts `CashReceived` for
  `amount_due` with the acting host as recipient. `at` is one instant stored both as the
  txn's time and as `bills.paid_at`. For `needs_review` the gateway money itself sits with
  the payout account owner; the spec's P0 limit applies (see "Batasan P0" in the spec).

  `cancel_cash` accepts a `paid` bill whose `paid_via` is `cash`; the Ledger rejects it
  with `:undo_window_expired` when `at` (now) is more than 24 hours after the cash txn's
  time, and requires a reason. The bill returns to `unpaid` with its paid fields cleared.

  An `Idempotency-Key` seen before returns the txn it posted (`replayed: true`) with no
  second txn, bill change or audit row, even though the bill has moved on since.
  """

  alias Petepete.Billing.{Bill, Locks, Replay, Transitions}
  alias Petepete.{Actor, Clock, Groups, HostAction, Ledger}
  alias Petepete.Ledger.Event.{CashPaymentCancelled, CashReceived}
  alias Petepete.Metrics

  @type result ::
          {:ok, %{bill: %Bill{}, txn: struct(), replayed: boolean()}} | {:error, term()}

  @doc "See `Petepete.Billing.mark_paid_cash/2`."
  @spec mark_paid_cash(pos_integer(), keyword()) :: result()
  def mark_paid_cash(bill_id, opts) when is_integer(bill_id) do
    run(bill_id, opts, "bill.mark_paid_cash", &mark_locked/5)
  end

  @doc "See `Petepete.Billing.cancel_cash/2`."
  @spec cancel_cash(pos_integer(), keyword()) :: result()
  def cancel_cash(bill_id, opts) when is_integer(bill_id) do
    run(bill_id, opts, "bill.cancel_cash", &cancel_locked/5)
  end

  defp run(bill_id, opts, action, locked_fun) do
    %Actor{type: :host} = actor = Keyword.fetch!(opts, :actor)
    key = Keyword.get(opts, :idempotency_key)

    with :ok <- Replay.require_key(key),
         group_id when is_integer(group_id) <-
           Groups.Policy.group_id_for(:bill, bill_id) || {:error, :not_found} do
      HostAction.run(actor, group_id, action, fn ->
        case Locks.lock_bills([bill_id]) do
          [bill] -> locked_fun.(bill, group_id, actor, key, opts)
          [] -> {:error, :not_found}
        end
      end)
    end
  end

  ## Tandai lunas

  defp mark_locked(bill, group_id, actor, key, _opts) do
    case Replay.find(key, "cash_received", "bill", bill.id) do
      {:ok, txn} ->
        replay(
          bill,
          Ledger.record(actor, cash_received(bill, group_id, key, txn.inserted_at))
        )

      {:error, _} = error ->
        error

      nil ->
        pay(bill, group_id, actor, key)
    end
  end

  defp pay(bill, group_id, actor, key) do
    at = Clock.now()

    with :ok <- Transitions.bill(bill.status, "paid", :mark_paid_cash),
         {:ok, %{txn: txn}} <-
           Ledger.record(actor, cash_received(bill, group_id, key, at)),
         {:ok, paid} <-
           Transitions.transition_bill(bill, "paid", :mark_paid_cash,
             paid_via: "cash",
             paid_txn_id: txn.id,
             paid_at: at
           ) do
      Metrics.record_paid(bill, group_id, at, :cash)

      audit = %{
        subject: {"txn", txn.id},
        metadata: %{
          "bill_id" => bill.id,
          "member_id" => bill.member_id,
          "amount" => bill.amount_due,
          "previous_status" => bill.status
        },
        replayed: false
      }

      {:ok, %{bill: paid, txn: txn, replayed: false}, audit}
    end
  end

  defp cash_received(bill, group_id, key, at) do
    %CashReceived{
      idempotency_key: key,
      group_id: group_id,
      bill_id: bill.id,
      member_id: bill.member_id,
      amount: bill.amount_due,
      at: at
    }
  end

  ## Batal cash

  defp cancel_locked(bill, group_id, actor, key, opts) do
    reason = Keyword.get(opts, :reason)

    case Replay.find(key, "cash_payment_cancelled", "bill", bill.id) do
      {:ok, txn} ->
        # The bill is unpaid again and no longer names the cash txn; the stored one does.
        event = cash_cancelled(group_id, key, txn.reverses_txn_id, reason, txn.inserted_at)
        replay(bill, Ledger.record(actor, event))

      {:error, _} = error ->
        error

      nil ->
        cancel(bill, group_id, actor, key, reason)
    end
  end

  defp cancel(bill, group_id, actor, key, reason) do
    with :ok <- Transitions.bill(bill.status, "unpaid", :cancel_cash),
         :ok <- cash_payment(bill),
         {:ok, %{txn: txn}} <-
           Ledger.record(
             actor,
             cash_cancelled(group_id, key, bill.paid_txn_id, reason, Clock.now())
           ),
         {:ok, unpaid} <- Transitions.transition_bill(bill, "unpaid", :cancel_cash) do
      audit = %{
        subject: {"txn", txn.id},
        metadata: %{
          "bill_id" => bill.id,
          "member_id" => bill.member_id,
          "amount" => bill.amount_due,
          "cash_txn_id" => bill.paid_txn_id,
          "reason" => reason
        },
        replayed: false
      }

      {:ok, %{bill: unpaid, txn: txn, replayed: false}, audit}
    end
  end

  defp cash_payment(%Bill{paid_via: "cash", paid_txn_id: id}) when is_integer(id), do: :ok
  defp cash_payment(_bill), do: {:error, :not_cash_payment}

  defp cash_cancelled(group_id, key, cash_txn_id, reason, at) do
    %CashPaymentCancelled{
      idempotency_key: key,
      group_id: group_id,
      txn_id: cash_txn_id,
      reason: reason,
      at: at
    }
  end

  defp replay(bill, {:ok, %{txn: txn, replayed: true}}) do
    {:ok, %{bill: bill, txn: txn, replayed: true},
     %{subject: {"txn", txn.id}, metadata: %{}, replayed: true}}
  end

  defp replay(_bill, {:error, _} = error), do: error
end
