defmodule PetepeteWeb.SessionBillingController do
  @moduledoc """
  Preview and issue of a draft session's bills (host only, checked by `SessionAccess`).

  `GET /api/sessions/:id/preview` returns `Billing.preview/1`: per-person, per-item parts,
  total billed vs total cost, credit used and the kas remainder ("Masuk kas").
  `POST /api/sessions/:id/issue` needs an `Idempotency-Key` header and returns the bills
  and `txn_id`; a repeated key returns the same bills with `replayed: true`.
  `POST /api/sessions/:id/void` (Batalkan tagihan, body `reason`, `Idempotency-Key` header)
  calls `Billing.void_issue/2` and returns the reversing `txn_id` (201, or 200 with
  `replayed: true` for a repeat), the `voided_bill_ids` and `cancelled_attempt_ids`.
  """
  use PetepeteWeb, :controller

  alias Petepete.Billing
  alias Petepete.Billing.TransitionError
  alias PetepeteWeb.{BillingError, FallbackController, LedgerError}

  plug PetepeteWeb.Plugs.SessionAccess, role: :host
  plug PetepeteWeb.Plugs.IdempotencyKey when action == :void

  def preview(conn, _params) do
    case Billing.preview(conn.assigns.session_id) do
      {:ok, preview} -> json(conn, encodable(preview))
      {:error, reason} -> error(conn, reason)
    end
  end

  def issue(conn, _params) do
    opts = [
      actor: {:host, conn.assigns.current_scope.user.id},
      idempotency_key: List.first(get_req_header(conn, "idempotency-key"))
    ]

    case Billing.issue(conn.assigns.session_id, opts) do
      {:ok, %{bills: bills, txn: txn, session: session, replayed: replayed}} ->
        json(conn, %{
          session_id: session.id,
          txn_id: txn.id,
          replayed: replayed,
          bills: Enum.map(bills, &bill_json/1)
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def void(conn, %{"reason" => reason}) when is_binary(reason) do
    opts = [
      actor: {:host, conn.assigns.current_scope.user.id},
      idempotency_key: conn.assigns.idempotency_key,
      reason: reason
    ]

    case Billing.void_issue(conn.assigns.session_id, opts) do
      {:ok, result} ->
        enqueue_cancellations(result)

        conn
        |> put_status(if result.replayed, do: 200, else: 201)
        |> json(%{
          txn_id: result.txn.id,
          replayed: result.replayed,
          session_id: result.session.id,
          voided_bill_ids: result.voided_bill_ids,
          cancelled_attempt_ids: result.cancelled_attempt_ids
        })

      {:error, reason} ->
        BillingError.render(conn, reason)
    end
  end

  def void(conn, _params), do: LedgerError.render(conn, :reason_required)

  # After the void committed: tell the gateway to drop the attempts the void cancelled.
  # A replay cancelled nothing new, so it enqueues nothing.
  defp enqueue_cancellations(%{replayed: true}), do: :ok
  defp enqueue_cancellations(%{cancelled_attempt_ids: []}), do: :ok

  defp enqueue_cancellations(%{cancelled_attempt_ids: ids}) do
    {:ok, _job} = Oban.insert(Petepete.Payments.CancelAttemptsJob.new(%{"attempt_ids" => ids}))
    :ok
  end

  defp encodable(preview) do
    Map.update!(preview, :fronted, fn fronted ->
      for {member_id, amount} <- fronted, do: %{member_id: member_id, amount: amount}
    end)
  end

  defp bill_json(bill) do
    %{
      id: bill.id,
      member_id: bill.member_id,
      display_name: bill.member.display_name,
      share: bill.share,
      credit_applied: bill.credit_applied,
      amount_due: bill.amount_due,
      status: bill.status,
      paid_via: bill.paid_via,
      pay_token: bill.pay_token,
      token_expires_at: bill.token_expires_at
    }
  end

  defp error(conn, :not_found), do: FallbackController.call(conn, {:error, :not_found})

  defp error(conn, %TransitionError{}),
    do: FallbackController.respond(conn, 409, "session_not_draft")

  defp error(conn, {:invalid, errors}) do
    conn
    |> put_status(422)
    |> json(%{error: "invalid_session", problems: Enum.map(errors, &problem/1)})
  end

  defp error(conn, :idempotency_key_required),
    do: FallbackController.respond(conn, 400, "idempotency_key_required")

  defp error(conn, :idempotency_key_conflict),
    do: FallbackController.respond(conn, 409, "idempotency_key_conflict")

  defp problem({code, id}), do: %{code: code, id: id}
  defp problem(code), do: %{code: code}
end
