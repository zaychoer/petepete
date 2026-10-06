defmodule PetepeteWeb.Plugs.OptionalAuthenticate do
  @moduledoc """
  For the few routes open to people without an account (joining by invite link).

  No `authorization` header: `conn.assigns.current_scope` is `nil`. A header that is
  present must be a valid bearer token (same as `PetepeteWeb.Plugs.Authenticate`);
  otherwise the request is halted with 401, never treated as anonymous.
  """
  @behaviour Plug

  import Plug.Conn

  alias PetepeteWeb.Plugs.Authenticate

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case get_req_header(conn, "authorization") do
      [] -> assign(conn, :current_scope, nil)
      _ -> Authenticate.call(conn, opts)
    end
  end
end
