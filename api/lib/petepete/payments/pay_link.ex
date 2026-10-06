defmodule Petepete.Payments.PayLink do
  @moduledoc """
  The unauthenticated pay link of a bill (`/pay/:token`): reading the pay page (PAY-04's
  data) and asking the gateway for a payment (PAY-02, PAY-06). The `pay_token` is the only
  credential; nothing here returns or logs a phone number.

  ## Attempts

  Every request that reaches the gateway is one `payment_attempts` row with
  `external_id` `<bill_id>-<seq>` (`seq` = last + 1 per bill), `fee` and `gross_amount`
  from `Petepete.Payments.fee_for/2`. A repeat request for the same method returns the
  still-active attempt (pending, not past `expires_at`); a different method or an expired
  attempt creates a new one, because the gateway rejects a reused order id. An attempt of
  another method stays pending, so a payer who paid with it is still matched by the
  webhook. If the gateway refuses the request the attempt is kept as `failed` (so its
  `seq` is never reused) and the caller gets `{:error, :gateway_error}`.

  An attempt expires after `attempt_ttl_seconds` (config
  `config :petepete, Petepete.Payments, attempt_ttl_seconds: n`, default 3600), never past
  the link's `token_expires_at`. A link works until its bill is paid or `token_expires_at`
  passes. Opening the page (`show/1`) marks overdue pending attempts `expired` and reports
  `attempt_expired`; the page then calls `start_payment/2` for a fresh one.

  ## Locking

  `start_payment/2` locks only the bill row (`Billing.lock_bills/1`), like the webhook and
  cash flows: it never touches the session row and never reaches the Ledger. The lock
  also serialises concurrent requests, so `seq` cannot collide and a double tap yields
  one attempt. The gateway call happens under that lock.
  """
  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing
  alias Petepete.Billing.Bill
  alias Petepete.Clock
  alias Petepete.Payments
  alias Petepete.Payments.PaymentAttempt
  alias Petepete.Repo

  @methods ~w(qris va ewallet)
  @default_ttl_seconds 3600

  @type start_error ::
          :not_found
          | :unsupported_method
          | :bill_paid
          | :bill_void
          | :bill_needs_review
          | :token_expired
          | :gateway_error

  @doc "The payment methods, in display order."
  @spec methods() :: [String.t()]
  def methods, do: @methods

  @doc """
  The pay page for `token`: `{:ok, view}` or `{:error, :not_found}`.

  `view` has `:bill`, `:page` (`Billing.pay_page/1`), `:token_expired`, `:can_pay`
  (unpaid and token valid), `:methods` (`[%{method, fee, gross_amount}]`, empty unless
  `can_pay`), `:attempt` (the newest active pending attempt or `nil`) and
  `:attempt_expired` (the bill is unpaid, no attempt is active and the latest one expired).
  Marks overdue pending attempts of an unpaid bill as `expired`.
  """
  @spec show(term()) :: {:ok, map()} | {:error, :not_found}
  def show(token) do
    case Billing.bill_by_token(token) do
      nil ->
        {:error, :not_found}

      %Bill{} = bill ->
        now = Clock.now()
        if bill.status == "unpaid", do: expire_overdue(bill.id, now)
        {:ok, view(bill, now)}
    end
  end

  defp view(bill, now) do
    token_expired = token_expired?(bill, now)
    can_pay = bill.status == "unpaid" and not token_expired
    active = newest_active_attempt(bill.id, now)

    %{
      bill: bill,
      page: Billing.pay_page(bill),
      token_expired: token_expired,
      can_pay: can_pay,
      methods: if(can_pay, do: method_fees(bill.amount_due), else: []),
      attempt: active,
      attempt_expired:
        bill.status == "unpaid" and is_nil(active) and latest_expired?(latest_attempt(bill.id))
    }
  end

  defp latest_expired?(%PaymentAttempt{status: "expired"}), do: true
  defp latest_expired?(_), do: false

  defp method_fees(amount_due) do
    for method <- @methods,
        {:ok, fee} <- [Payments.fee_for(method, amount_due)],
        do: %{method: method, fee: fee, gross_amount: amount_due + fee}
  end

  @doc """
  Creates (or returns the active) payment attempt of the bill behind `token` for `method`.

  `{:ok, %{attempt: attempt, reused: boolean}}`, or `{:error, reason}` (see `t:start_error/0`):
  a paid, void or `needs_review` bill and an expired link are rejected with their own reason.
  """
  @spec start_payment(term(), term()) ::
          {:ok, %{attempt: PaymentAttempt.t(), reused: boolean()}} | {:error, start_error()}
  def start_payment(token, method) do
    with :ok <- check_method(method),
         %Bill{} = bill <- Billing.bill_by_token(token) || {:error, :not_found} do
      transact(bill.id, method)
    end
  end

  defp check_method(method) when method in @methods, do: :ok
  defp check_method(_), do: {:error, :unsupported_method}

  defp transact(bill_id, method) do
    result =
      Repo.transaction(fn ->
        [bill] = Billing.lock_bills([bill_id])
        now = Clock.now()

        with :ok <- check_payable(bill, now) do
          expire_overdue(bill.id, now)

          case active_attempt(bill.id, method, now) do
            %PaymentAttempt{} = attempt -> {:ok, %{attempt: attempt, reused: true}}
            nil -> create_attempt(bill, method, now)
          end
        end
      end)

    # Every outcome is a committed value (a failed gateway call keeps its row), never a rollback.
    {:ok, reply} = result
    reply
  end

  defp check_payable(%Bill{status: "paid"}, _now), do: {:error, :bill_paid}
  defp check_payable(%Bill{status: "void"}, _now), do: {:error, :bill_void}
  defp check_payable(%Bill{status: "needs_review"}, _now), do: {:error, :bill_needs_review}

  defp check_payable(%Bill{status: "unpaid"} = bill, now) do
    if token_expired?(bill, now), do: {:error, :token_expired}, else: :ok
  end

  defp token_expired?(%Bill{status: "paid"}, _now), do: false

  defp token_expired?(%Bill{token_expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  defp create_attempt(bill, method, now) do
    gateway = Payments.gateway()

    with {:ok, fee} <- Payments.fee_for(method, bill.amount_due) do
      seq = last_seq(bill.id) + 1
      external_id = "#{bill.id}-#{seq}"
      gross = bill.amount_due + fee
      expires_at = attempt_expiry(now, bill)

      attempt =
        Repo.insert!(%PaymentAttempt{
          bill_id: bill.id,
          seq: seq,
          external_id: external_id,
          provider: gateway.provider(),
          method: method,
          amount_due: bill.amount_due,
          fee: fee,
          gross_amount: gross,
          expires_at: expires_at
        })

      request = %{
        external_id: external_id,
        method: method,
        gross_amount: gross,
        expires_at: expires_at
      }

      case gateway.create_payment(request) do
        {:ok, payment} ->
          updated =
            attempt
            |> Ecto.Changeset.change(
              provider_ref: payment.provider_ref,
              action: payment.action,
              expires_at: DateTime.truncate(payment.expires_at, :second)
            )
            |> Repo.update!()

          {:ok, %{attempt: updated, reused: false}}

        {:error, _reason} ->
          attempt |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
          # Commit the failed row: its seq must never be handed out again.
          {:error, :gateway_error}
      end
    else
      {:error, _} -> {:error, :unsupported_method}
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

  defp latest_attempt(bill_id) do
    Repo.one(
      from a in PaymentAttempt, where: a.bill_id == ^bill_id, order_by: [desc: a.seq], limit: 1
    )
  end

  defp newest_active_attempt(bill_id, now) do
    Repo.one(
      from a in PaymentAttempt,
        where: a.bill_id == ^bill_id and a.status == "pending" and a.expires_at > ^now,
        order_by: [desc: a.seq],
        limit: 1
    )
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

  # Guarded on status so a concurrent webhook that settles the attempt wins.
  defp expire_overdue(bill_id, now) do
    Repo.update_all(
      from(a in PaymentAttempt,
        where: a.bill_id == ^bill_id and a.status == "pending" and a.expires_at <= ^now
      ),
      set: [status: "expired", updated_at: now]
    )
  end
end
