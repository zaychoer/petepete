defmodule PetepeteWeb.Plugs.BillAccess do
  @moduledoc """
  Authorizes the caller against the group of the bill in the `id` path param.

      plug PetepeteWeb.Plugs.BillAccess, role: :host

  Resolves the group with `Groups.group_id_for(:bill, id)`, then authorizes. On success
  assigns `conn.assigns.group_id`, `:bill_id` and, per `PetepeteWeb.Plugs.Access`, `:member`
  (role `:member`) or `:actor` and `:member` (role `:host`); otherwise halts with 404
  (unknown bill or not a member of its group) or 403 (not the host). Requires
  `conn.assigns.current_scope`.
  """
  @behaviour Plug

  alias Petepete.Groups
  alias PetepeteWeb.Plugs.Access

  @impl true
  def init(opts), do: Keyword.get(opts, :role, :member)

  @impl true
  def call(conn, role) do
    with {:ok, bill_id} <- Access.parse_id(conn.params["id"]),
         group_id when is_integer(group_id) <- Groups.group_id_for(:bill, bill_id) do
      conn
      |> Access.authorize(group_id, role)
      |> assign_id(bill_id)
    else
      {:error, reason} -> Access.halt_with(conn, reason)
      nil -> Access.halt_with(conn, :not_found)
    end
  end

  defp assign_id(%Plug.Conn{halted: true} = conn, _id), do: conn
  defp assign_id(conn, id), do: Plug.Conn.assign(conn, :bill_id, id)
end
