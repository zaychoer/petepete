defmodule PetepeteWeb.Plugs.Authenticate do
  @moduledoc """
  Requires `authorization: Bearer <access token>`.

  Assigns `conn.assigns.current_scope` (`Petepete.Accounts.Scope`); otherwise halts
  with 401 `unauthenticated` (`PetepeteWeb.FallbackController`).
  """
  @behaviour Plug

  import Plug.Conn

  alias Petepete.Accounts

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, scope} <- Accounts.authenticate_access_token(token) do
      assign(conn, :current_scope, scope)
    else
      _ ->
        conn
        |> PetepeteWeb.FallbackController.respond(401, "unauthenticated")
        |> halt()
    end
  end
end
