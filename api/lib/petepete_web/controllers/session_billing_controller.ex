defmodule PetepeteWeb.SessionBillingController do
  @moduledoc """
  Preview and issue of a draft session's bills (host only, checked by `SessionAccess`).

  `GET /api/sessions/:id/preview` returns `Billing.preview/1`: per-person, per-item parts,
  total billed vs total cost, credit used and the kas remainder ("Masuk kas").
  `POST /api/sessions/:id/issue` needs an `Idempotency-Key` header and returns the bills
  and `txn_id`; a repeated key returns the same bills with `replayed: true`.
  """
  use PetepeteWeb, :controller

  alias Petepete.Billing
  alias Petepete.Billing.TransitionError
  alias PetepeteWeb.FallbackController

  plug PetepeteWeb.Plugs.SessionAccess, role: :host

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
