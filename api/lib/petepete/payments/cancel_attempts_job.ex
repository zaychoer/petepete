defmodule Petepete.Payments.CancelAttemptsJob do
  @moduledoc """
  Oban job that cancels payment attempts at the gateway after `Billing.void_issue/2`
  marked them `cancelled` in its own transaction (best effort).

  Args: `%{"attempt_ids" => [id, ...]}`, enqueued with
  `Petepete.Payments.CancelAttemptsJob.new(%{"attempt_ids" => ids}) |> Oban.insert()`.
  Each attempt with a `provider_ref` goes to `gateway.cancel_payment/1`. A gateway
  without that API (`{:error, :unsupported}`) is fine: the attempt is already cancelled on
  our side, and a payment that still arrives is handled by the webhook flow. Any other
  error fails the job so Oban retries it; the retry asks the gateway again for every attempt,
  so an adapter's `cancel_payment/1` must tolerate an already cancelled payment.
  """
  use Oban.Worker, queue: :payments, max_attempts: 5

  import Ecto.Query, only: [from: 2]

  alias Petepete.Payments
  alias Petepete.Payments.PaymentAttempt
  alias Petepete.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"attempt_ids" => ids}}) when is_list(ids) do
    gateway = Payments.gateway()

    refs =
      Repo.all(
        from a in PaymentAttempt,
          where: a.id in ^ids and not is_nil(a.provider_ref),
          order_by: a.id,
          select: a.provider_ref
      )

    failures =
      for ref <- refs,
          result = gateway.cancel_payment(ref),
          result not in [:ok, {:error, :unsupported}],
          do: {ref, result}

    case failures do
      [] -> :ok
      [{_ref, {:error, reason}} | _] -> {:error, {:cancel_failed, length(failures), reason}}
    end
  end
end
