defmodule PetepeteWeb.PayoutAccountController do
  @moduledoc """
  Rekening pencairan: the host registers themself as the group's payout account owner.
  The context (`Payments.register_payout_account/3`) writes the audit row with the account.
  """
  use PetepeteWeb, :controller

  alias Petepete.Payments
  alias PetepeteWeb.{LedgerError, Plugs.GroupAccess}

  plug GroupAccess, role: :host

  def create(conn, params) do
    result = Payments.register_payout_account(conn.assigns.actor, conn.assigns.group_id, params)

    case result do
      {:ok, account} ->
        conn
        |> put_status(201)
        |> json(%{payout_account_id: account.id, status: account.status})

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
