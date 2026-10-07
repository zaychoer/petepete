defmodule PetepeteWeb.Plugs.IdempotencyKey do
  @moduledoc """
  Requires the `Idempotency-Key` header on money-writing endpoints and assigns it as
  `conn.assigns.idempotency_key` (it becomes the Ledger's `idempotency_key`).
  Missing or blank: halts with 422 `idempotency_key_required`.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "idempotency-key") do
      [key | _] when is_binary(key) ->
        case String.trim(key) do
          "" -> reject(conn)
          trimmed -> assign(conn, :idempotency_key, trimmed)
        end

      _ ->
        reject(conn)
    end
  end

  defp reject(conn),
    do: conn |> PetepeteWeb.LedgerError.render(:idempotency_key_required) |> halt()
end
