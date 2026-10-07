defmodule Petepete.Billing.GatewayPayments do
  @moduledoc """
  `Billing.apply_gateway_payment/2`: the hand-off from the webhook (spec "Alur webhook",
  step 6, ADR-0001/0002). `Petepete.Payments` compares the paid amount with the attempt's
  `gross_amount` and calls this inside its webhook transaction, with the bill already
  locked in the Billing lock order (session rows are never touched). The bill is locked
  again here, which costs nothing inside the same transaction, so the function also holds
  when called alone; outside a transaction it raises.

  Billing decides what the payment means for the bill and posts to the Ledger; it never
  writes `gateway_notifications` or an attempt's status. The only attempt column it writes
  is `paid_amount`, in every outcome, on the attempt named by `attempt_id` (which must
  belong to the bill).

  | Bill | Amount | Result |
  | --- | --- | --- |
  | `unpaid` | does not match | `needs_review` (stored `paid_amount`); nothing posted → `{:ok, :needs_review}` |
  | `unpaid` | matches | `GatewayPaymentReceived` (Actor gateway, `amount_due`); bill `paid`, `paid_via` gateway, `paid_txn_id`, `paid_at` → `{:ok, :paid}` |
  | `paid` or `void` | any | `GatewayPaymentReceived` for `amount_due` stays as participant credit; bill unchanged → `{:ok, :overpaid}` |

  Two cases the spec's table does not spell out, resolved by its literal rule order:

    * A mismatching amount on a `paid` or `void` bill falls under the third rule: the credit
      posted is `amount_due`, not the odd amount, whose real figure (with gateway fee) is
      only in the attempt's `paid_amount` for the host to review.
    * A `needs_review` bill waits for the host (Tandai lunas or Catat pelunasan) because the
      state diagram lets only `mark_paid_cash` leave `needs_review`. A new mismatching
      payment leaves it `needs_review` (`{:ok, :needs_review}`); a matching one is posted as
      credit (`{:ok, :overpaid}`).

  The `idempotency_key` goes to the Ledger as is. A key seen before posts nothing and
  changes no bill: the answer is `:paid` when that txn is the one that paid the bill,
  otherwise `:overpaid`.
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing.{Bill, Locks, Transitions}
  alias Petepete.{Actor, Clock, Groups, Ledger}
  alias Petepete.Ledger.Event.GatewayPaymentReceived
  alias Petepete.Metrics
  alias Petepete.Payments.PaymentAttempt
  alias Petepete.Repo

  @type params :: %{
          paid_amount: integer(),
          matches_expected: boolean(),
          idempotency_key: String.t(),
          attempt_id: pos_integer()
        }

  @doc "See `Petepete.Billing.apply_gateway_payment/2`."
  @spec apply_gateway_payment(pos_integer(), params()) ::
          {:ok, :paid | :needs_review | :overpaid} | {:error, term()}
  def apply_gateway_payment(bill_id, %{
        paid_amount: paid_amount,
        matches_expected: matches?,
        idempotency_key: key,
        attempt_id: attempt_id
      })
      when is_integer(bill_id) and is_integer(paid_amount) and is_boolean(matches?) and
             is_binary(key) and is_integer(attempt_id) do
    with {:ok, bill} <- lock_bill(bill_id),
         {:ok, attempt} <- fetch_attempt(bill, attempt_id),
         {:ok, outcome} <- decide(bill, matches?, key) do
      record_paid_amount(attempt, paid_amount)
      {:ok, outcome}
    end
  end

  defp lock_bill(bill_id) do
    case Locks.lock_bills([bill_id]) do
      [bill] -> {:ok, bill}
      [] -> {:error, :not_found}
    end
  end

  defp fetch_attempt(%Bill{id: bill_id}, attempt_id) do
    case Repo.one(from a in PaymentAttempt, where: a.id == ^attempt_id and a.bill_id == ^bill_id) do
      nil -> {:error, :attempt_not_found}
      attempt -> {:ok, attempt}
    end
  end

  defp record_paid_amount(%PaymentAttempt{id: id}, paid_amount) do
    Repo.update_all(from(a in PaymentAttempt, where: a.id == ^id),
      set: [paid_amount: paid_amount, updated_at: DateTime.utc_now(:second)]
    )
  end

  defp decide(%Bill{status: "unpaid"} = bill, false, _key) do
    with {:ok, _} <- Transitions.transition_bill(bill, "needs_review", :gateway_amount_mismatch) do
      {:ok, :needs_review}
    end
  end

  defp decide(%Bill{status: "needs_review"}, false, _key), do: {:ok, :needs_review}

  defp decide(%Bill{status: "unpaid"} = bill, true, key) do
    with {:ok, %{txn: txn, replayed: replayed}} <- post(bill, key) do
      if replayed do
        {:ok, outcome_of_replay(bill, txn)}
      else
        paid_at = Clock.now()

        with {:ok, _} <-
               Transitions.transition_bill(bill, "paid", :gateway_payment,
                 paid_via: "gateway",
                 paid_txn_id: txn.id,
                 paid_at: paid_at
               ) do
          Metrics.record_paid(bill, Groups.Policy.group_id_for(:bill, bill.id), paid_at, :gateway)
          {:ok, :paid}
        end
      end
    end
  end

  # Third rule: a paid or void bill (or a matching payment for a needs_review bill) keeps
  # the money as credit of the member.
  defp decide(%Bill{} = bill, _matches?, key) do
    with {:ok, %{txn: txn, replayed: replayed}} <- post(bill, key) do
      {:ok, if(replayed, do: outcome_of_replay(bill, txn), else: :overpaid)}
    end
  end

  defp outcome_of_replay(%Bill{paid_txn_id: id}, %{id: id}), do: :paid
  defp outcome_of_replay(_bill, _txn), do: :overpaid

  defp post(%Bill{} = bill, key) do
    Ledger.record(Actor.gateway(), %GatewayPaymentReceived{
      idempotency_key: key,
      group_id: Groups.Policy.group_id_for(:bill, bill.id),
      bill_id: bill.id,
      member_id: bill.member_id,
      amount: bill.amount_due
    })
  end
end
