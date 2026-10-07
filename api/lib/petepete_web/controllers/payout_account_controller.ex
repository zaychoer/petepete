defmodule PetepeteWeb.PayoutAccountController do
  @moduledoc """
  Rekening pencairan: the host registers themself as the group's payout account owner.
  The context (`Payments.register_payout_account/4`) writes the audit row with the account.

  `POST /groups/:group_id/payout-account` needs an `Idempotency-Key` header: 201 for a new
  account, 200 with the original account (`replayed: true`) for a repeated key.
  """
  use PetepeteWeb, :controller

  alias Petepete.Payments
  alias PetepeteWeb.LedgerError
  alias PetepeteWeb.Plugs.{GroupAccess, IdempotencyKey}

  plug GroupAccess, role: :host
  plug IdempotencyKey

  def create(conn, params) do
    result =
      Payments.register_payout_account(
        conn.assigns.actor,
        conn.assigns.group_id,
        conn.assigns.idempotency_key,
        params
      )

    case result do
      {:ok, %{payout_account: account, replayed: replayed}} ->
        conn
        |> put_status(if replayed, do: 200, else: 201)
        |> json(%{payout_account_id: account.id, status: account.status, replayed: replayed})

      {:error, %Ecto.Changeset{} = changeset} ->
        LedgerError.render_invalid(conn, changeset_errors(changeset))

      {:error, _reason} ->
        conn
        |> put_status(502)
        |> json(%{error: "gateway_error", message: "Gateway sedang bermasalah. Coba lagi nanti."})
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
