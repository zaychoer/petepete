defmodule Petepete.Payments.Webhook do
  @moduledoc """
  The gateway webhook flow (spec "Alur webhook", ADR-0002): `POST /api/webhooks/:provider`
  lands in `handle/4`.

    1. Only the configured gateway's provider name is served; anything else is
       `{:error, :unknown_provider}`. The adapter verifies the request from the raw body
       and headers; failure is `{:error, :invalid_signature}` and is reported to Sentry
       (never with the payload, which carries phone numbers).
    2. The adapter normalizes the payload into `provider_txn_id`, status, `external_id`
       and the paid amount.
    3. One database transaction does the rest. A `gateway_notifications` row is inserted
       `ON CONFLICT DO NOTHING` on `(provider, provider_txn_id, provider_status)` and then
       read `FOR UPDATE`, so concurrent deliveries of the same notification queue up and the
       later ones see `processed_at` and stop. A different status of the same transaction
       (pending, then paid) is a different notification.
    4. The attempt is found by `external_id` (none: outcome `unknown`, reported to Sentry),
       then its bill is locked with `Billing.lock_bills/1`; the session row is never touched
       (lock order session, bills by id, Ledger group lock).
    5. A pending, expired or failed notification only updates the attempt's status; an
       attempt that already left `pending` (paid, cancelled) is not moved back.
    6. A paid notification: Payments compares the paid amount with the attempt's
       `gross_amount` and hands over to `Billing.apply_gateway_payment/2`, which decides the
       bill's fate and posts to the Ledger with the key `<provider>:<provider_txn_id>:<status>`.
       The attempt becomes `paid` only when the bill was paid by it.
    7. `processed_at` and `outcome` (`paid`, `needs_review`, `overpaid`, `unknown`, or the
       status name for steps 5) are stored and the transaction commits. Any failure rolls
       everything back and answers `{:error, :processing_failed}` (HTTP 500), so the
       gateway sends the notification again and it is processed from the start.

  `handle/4` returns `{:ok, outcome}` (a string) when the notification is processed now or
  was before.
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.{Billing, Clock, PhoneMask, Repo}
  alias Petepete.Payments
  alias Petepete.Payments.{GatewayNotification, PaymentAttempt}

  require Logger

  @type result ::
          {:ok, String.t()}
          | {:error,
             :unknown_provider | :invalid_signature | :malformed_payload | :processing_failed}

  @doc """
  Verifies, normalizes and processes one webhook delivery. `payload` is the decoded JSON
  body, `raw_body` the exact bytes the signature covers, `headers` the request headers
  (lowercase names).
  """
  @spec handle(String.t(), [{String.t(), String.t()}], binary(), map()) :: result()
  def handle(provider, headers, raw_body, payload) when is_binary(provider) do
    gateway = Payments.gateway()

    with :ok <- check_provider(gateway, provider),
         :ok <- verify(gateway, headers, raw_body),
         {:ok, notification} <- normalize(gateway, payload) do
      process(provider, notification, payload)
    end
  end

  defp check_provider(gateway, provider) do
    if gateway.provider() == provider, do: :ok, else: {:error, :unknown_provider}
  end

  defp verify(gateway, headers, raw_body) do
    case gateway.verify_webhook(headers, raw_body) do
      :ok ->
        :ok

      {:error, :invalid_signature} ->
        report("Webhook gateway ditolak: signature tidak valid", provider: gateway.provider())
        {:error, :invalid_signature}
    end
  end

  defp normalize(gateway, payload) do
    case gateway.normalize_webhook(payload) do
      {:ok, %{status: :paid, paid_amount: amount}} = ok when is_integer(amount) and amount >= 0 ->
        ok

      {:ok, %{status: status}} = ok when status != :paid ->
        ok

      _ ->
        report("Webhook gateway tidak bisa dibaca", provider: gateway.provider())
        {:error, :malformed_payload}
    end
  end

  defp process(provider, notification, payload) do
    case Repo.transaction(fn -> in_transaction(provider, notification, payload) end) do
      {:ok, outcome} ->
        {:ok, outcome}

      {:error, reason} ->
        failed(provider, notification, reason)
    end
  rescue
    exception ->
      Sentry.capture_exception(exception,
        stacktrace: __STACKTRACE__,
        extra: %{provider: provider, provider_txn_id: notification.provider_txn_id}
      )

      Logger.error("Webhook #{provider} gagal diproses: #{inspect(exception.__struct__)}")
      {:error, :processing_failed}
  end

  defp failed(provider, notification, reason) do
    report("Webhook gateway gagal diproses",
      provider: provider,
      provider_txn_id: notification.provider_txn_id,
      reason: inspect(reason)
    )

    {:error, :processing_failed}
  end

  defp in_transaction(provider, notification, payload) do
    row = lock_notification(provider, notification, payload)

    if row.processed_at do
      row.outcome
    else
      outcome = apply_notification(provider, notification)

      Repo.update_all(from(n in GatewayNotification, where: n.id == ^row.id),
        set: [outcome: outcome, processed_at: Clock.now()]
      )

      outcome
    end
  end

  defp lock_notification(provider, notification, payload) do
    status = Atom.to_string(notification.status)
    txn_id = notification.provider_txn_id

    Repo.insert_all(
      GatewayNotification,
      [
        %{
          provider: provider,
          provider_txn_id: txn_id,
          provider_status: status,
          payload: payload,
          inserted_at: Clock.now()
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:provider, :provider_txn_id, :provider_status]
    )

    Repo.one!(
      from n in GatewayNotification,
        where:
          n.provider == ^provider and n.provider_txn_id == ^txn_id and
            n.provider_status == ^status,
        lock: "FOR UPDATE"
    )
  end

  defp apply_notification(provider, notification) do
    with %PaymentAttempt{} = found <-
           Repo.get_by(PaymentAttempt, external_id: notification.external_id),
         true <- found.provider == provider,
         [_bill] <- Billing.lock_bills([found.bill_id]) do
      # Re-read under the bill lock: a concurrent void may have cancelled it meanwhile.
      attempt = Repo.get!(PaymentAttempt, found.id)
      settle(provider, attempt, notification)
    else
      _ ->
        report("Webhook untuk attempt yang tidak dikenal",
          provider: provider,
          provider_txn_id: notification.provider_txn_id
        )

        "unknown"
    end
  end

  defp settle(_provider, attempt, %{status: status})
       when status in [:pending, :expired, :failed] do
    if status != :pending and attempt.status == "pending" do
      Repo.update_all(from(a in PaymentAttempt, where: a.id == ^attempt.id),
        set: [status: Atom.to_string(status), updated_at: Clock.now()]
      )
    end

    Atom.to_string(status)
  end

  defp settle(provider, attempt, %{status: :paid} = notification) do
    params = %{
      paid_amount: notification.paid_amount,
      matches_expected: notification.paid_amount == attempt.gross_amount,
      idempotency_key: "#{provider}:#{notification.provider_txn_id}:paid",
      attempt_id: attempt.id
    }

    case Billing.apply_gateway_payment(attempt.bill_id, params) do
      {:ok, outcome} ->
        fault_hook()
        if outcome == :paid, do: mark_attempt_paid(attempt)
        Atom.to_string(outcome)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp mark_attempt_paid(attempt) do
    Repo.update_all(from(a in PaymentAttempt, where: a.id == ^attempt.id),
      set: [status: "paid", updated_at: Clock.now()]
    )
  end

  # A test seam: lets a test crash the flow after the Ledger post to prove the rollback.
  # Unset (the default) it does nothing.
  defp fault_hook do
    case Application.get_env(:petepete, :webhook_fault_hook) do
      nil -> :ok
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp report(message, extra) do
    Sentry.capture_message(message, extra: PhoneMask.scrub(Map.new(extra)))
  end
end
