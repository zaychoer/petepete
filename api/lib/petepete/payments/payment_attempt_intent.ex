defmodule Petepete.Payments.PaymentAttemptIntent do
  @moduledoc """
  Outbound intent for payment attempts (ADR-0005).

  `prepare` = lock bill, check payable, find active attempt or insert pending.
  `request` = `gateway.create_payment`.
  `settle` = write provider data (accept) or mark failed (refuse).
  `recover` = `:redrive` up to max_retries, then `:fail`.
  """
  @behaviour Petepete.Payments.OutboundIntent

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing
  alias Petepete.Billing.Bill
  alias Petepete.Clock
  alias Petepete.Payments
  alias Petepete.Payments.PaymentAttempt
  alias Petepete.Repo

  @default_ttl_seconds 3600

  @impl true
  def kind, do: "payment_attempt"

  @impl true
  def prepare(%{bill_id: bill_id, method: method}) do
    [bill] = Billing.lock_bills([bill_id])
    now = Clock.now()

    with :ok <- check_payable(bill, now) do
      expire_overdue(bill.id, now)

      case active_attempt(bill.id, method, now) do
        %PaymentAttempt{provider_ref: ref} = attempt when is_binary(ref) ->
          # Already has provider data – settled (from the runner's perspective).
          {:ok, attempt, attempt.external_id}

        %PaymentAttempt{} = attempt ->
          # Pending without provider data – needs request.
          {:ok, attempt, attempt.external_id}

        nil ->
          attempt = insert_attempt(bill, method, now)
          {:ok, attempt, attempt.external_id}
      end
    end
  end

  @impl true
  def request(_row, reference) do
    attempt = Repo.get_by!(PaymentAttempt, external_id: reference)
    gateway = Payments.gateway()

    request = %{
      external_id: attempt.external_id,
      method: attempt.method,
      gross_amount: attempt.gross_amount,
      expires_at: attempt.expires_at
    }

    case gateway.create_payment(request) do
      {:ok, payment} -> {:ok, payment}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def settle(row, {:ok, payment}) do
    attempt = Repo.get!(PaymentAttempt, row.id)
    gateway = Payments.gateway()

    Repo.update_all(
      from(a in PaymentAttempt, where: a.id == ^attempt.id),
      set: [
        provider_ref: payment.provider_ref,
        action: payment.action,
        expires_at: DateTime.truncate(payment.expires_at, :second),
        updated_at: Clock.now()
      ]
    )

    case Repo.get!(PaymentAttempt, attempt.id) do
      %PaymentAttempt{status: "cancelled"} ->
        _ = gateway.cancel_payment(payment.provider_ref)
        {:error, :bill_void}

      %PaymentAttempt{} = updated ->
        {:ok, updated}
    end
  end

  def settle(row, {:error, _reason}) do
    Repo.update_all(
      from(a in PaymentAttempt, where: a.id == ^row.id and a.status == "pending"),
      set: [status: "failed", updated_at: Clock.now()]
    )

    {:error, :gateway_error}
  end

  @impl true
  def stuck(threshold) do
    Repo.all(
      from a in PaymentAttempt,
        where: a.status == "pending" and is_nil(a.provider_ref) and a.inserted_at < ^threshold,
        order_by: a.id
    )
  end

  @impl true
  def recover(row) do
    max_retries =
      :petepete
      |> Application.get_env(Petepete.Payments, [])
      |> Keyword.get(:intent_max_retries, 3)

    if row.retry_count >= max_retries, do: :fail, else: :redrive
  end

  # -- Private helpers (moved from PayLink) --

  defp check_payable(%Bill{status: "paid"}, _now), do: {:error, :bill_paid}
  defp check_payable(%Bill{status: "void"}, _now), do: {:error, :bill_void}
  defp check_payable(%Bill{status: "needs_review"}, _now), do: {:error, :bill_needs_review}

  defp check_payable(%Bill{status: "unpaid"} = bill, now) do
    if token_expired?(bill, now), do: {:error, :token_expired}, else: :ok
  end

  defp token_expired?(%Bill{status: "paid"}, _now), do: false

  defp token_expired?(%Bill{token_expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  defp insert_attempt(bill, method, now) do
    gateway = Payments.gateway()

    case Payments.fee_for(method, bill.amount_due) do
      {:ok, fee} ->
        seq = last_seq(bill.id) + 1

        Repo.insert!(%PaymentAttempt{
          bill_id: bill.id,
          seq: seq,
          external_id: "#{bill.id}-#{seq}",
          provider: gateway.provider(),
          method: method,
          amount_due: bill.amount_due,
          fee: fee,
          gross_amount: bill.amount_due + fee,
          expires_at: attempt_expiry(now, bill)
        })

      {:error, _} ->
        Repo.rollback(:unsupported_method)
    end
  end

  defp attempt_expiry(now, bill) do
    ttl =
      :petepete
      |> Application.get_env(Petepete.Payments, [])
      |> Keyword.get(:attempt_ttl_seconds, @default_ttl_seconds)

    Enum.min([DateTime.add(now, ttl, :second), bill.token_expires_at], DateTime)
  end

  defp last_seq(bill_id) do
    Repo.one(from a in PaymentAttempt, where: a.bill_id == ^bill_id, select: max(a.seq)) || 0
  end

  defp active_attempt(bill_id, method, now) do
    Repo.one(
      from a in PaymentAttempt,
        where:
          a.bill_id == ^bill_id and a.method == ^method and a.status == "pending" and
            a.expires_at > ^now,
        order_by: [desc: a.seq],
        limit: 1
    )
  end

  defp expire_overdue(bill_id, now) do
    Repo.update_all(
      from(a in PaymentAttempt,
        where: a.bill_id == ^bill_id and a.status == "pending" and a.expires_at <= ^now
      ),
      set: [status: "expired", updated_at: now]
    )
  end
end
