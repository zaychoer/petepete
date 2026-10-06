defmodule PetepeteWeb.BillController do
  @moduledoc """
  Host-only cash handling of a bill (group resolved from the bill by `BillAccess`).

  `POST /api/bills/:id/cash` (Tandai cash) → `Billing.mark_paid_cash/2`.
  `POST /api/bills/:id/cash/cancel` (Batal cash, body `reason`) → `Billing.cancel_cash/2`.

  Both need an `Idempotency-Key` header and answer `{txn_id, replayed, bill}`: 201 for a
  new txn, 200 for a replay of the same request.
  """
  use PetepeteWeb, :controller

  alias Petepete.Billing
  alias PetepeteWeb.{BillingError, Labels, LedgerError}
  alias PetepeteWeb.Plugs.{BillAccess, IdempotencyKey}

  plug BillAccess, role: :host
  plug IdempotencyKey

  def cash(conn, _params) do
    conn.assigns.bill_id |> Billing.mark_paid_cash(opts(conn)) |> respond(conn)
  end

  def cancel_cash(conn, %{"reason" => reason}) when is_binary(reason) do
    conn.assigns.bill_id |> Billing.cancel_cash([reason: reason] ++ opts(conn)) |> respond(conn)
  end

  def cancel_cash(conn, _params), do: LedgerError.render(conn, :reason_required)

  defp opts(conn) do
    [
      actor: conn.assigns.actor,
      idempotency_key: conn.assigns.idempotency_key
    ]
  end

  defp respond({:ok, %{bill: bill, txn: txn, replayed: replayed}}, conn) do
    conn
    |> put_status(if replayed, do: 200, else: 201)
    |> json(%{
      txn_id: txn.id,
      replayed: replayed,
      bill: %{
        id: bill.id,
        status: bill.status,
        status_label: Labels.bill(bill.status),
        paid_via: bill.paid_via,
        paid_via_label: Labels.paid_via(bill.paid_via),
        paid_at: bill.paid_at,
        amount_due: bill.amount_due
      }
    })
  end

  defp respond({:error, reason}, conn), do: BillingError.render(conn, reason)
end
