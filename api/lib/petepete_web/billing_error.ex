defmodule PetepeteWeb.BillingError do
  @moduledoc """
  Renders the error of a Billing money command: 404 `not_found`, 409 `invalid_transition`
  (a status change the state machine does not allow, with the entity and its current
  status), 422 `not_cash_payment`, and every other reason through `PetepeteWeb.LedgerError`
  (422 with a stable code and an Indonesian message).
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Petepete.Billing.TransitionError
  alias PetepeteWeb.{FallbackController, LedgerError}

  @doc "Sends the error response and returns the conn."
  @spec render(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def render(conn, :not_found), do: FallbackController.call(conn, {:error, :not_found})

  def render(conn, %TransitionError{entity: entity, from: from}) do
    conn
    |> put_status(409)
    |> json(%{
      error: "invalid_transition",
      entity: Atom.to_string(entity),
      status: from,
      message: transition_message(entity)
    })
  end

  def render(conn, :not_cash_payment) do
    conn
    |> put_status(422)
    |> json(%{
      error: "not_cash_payment",
      message: "Tagihan ini tidak dibayar cash, jadi tidak bisa dibatalkan di sini."
    })
  end

  def render(conn, reason) when is_atom(reason), do: LedgerError.render(conn, reason)

  defp transition_message(:session),
    do: "Sesi ini tidak bisa dibatalkan tagihannya dalam status sekarang."

  defp transition_message(:bill), do: "Status tagihan ini tidak bisa diubah dengan aksi itu."
end
