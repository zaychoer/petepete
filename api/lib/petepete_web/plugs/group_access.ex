defmodule PetepeteWeb.Plugs.GroupAccess do
  @moduledoc """
  Authorizes the caller against the `group_id` path param.

      plug PetepeteWeb.Plugs.GroupAccess, role: :host

  On success assigns `conn.assigns.group_id` and, per `PetepeteWeb.Plugs.Access`,
  `:member` (role `:member`) or `:actor` and `:member` (role `:host`); otherwise halts with
  404/403 JSON. Requires `conn.assigns.current_scope` (set by the `:authenticated` pipeline).
  """
  @behaviour Plug

  alias PetepeteWeb.Plugs.Access

  @impl true
  def init(opts), do: Keyword.get(opts, :role, :member)

  @impl true
  def call(conn, role) do
    case Access.parse_id(conn.params["group_id"]) do
      {:ok, group_id} -> Access.authorize(conn, group_id, role)
      {:error, reason} -> Access.halt_with(conn, reason)
    end
  end
end
