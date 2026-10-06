defmodule PetepeteWeb.Plugs.BillAccess do
  @moduledoc """
  Authorizes the caller against the group of the bill in the `id` path param.

      plug PetepeteWeb.Plugs.BillAccess, role: :host

  Resolves the group with `Groups.group_id_for(:bill, id)`, then authorizes. On success
  assigns `conn.assigns.member`, `:group_id` and `:bill_id`; otherwise halts with 404
  (unknown bill or not a member of its group) or 403 (not the host). Requires
  `conn.assigns.current_scope`.
  """
  @behaviour Plug

  alias Petepete.Groups
  alias PetepeteWeb.FallbackController

  @impl true
  def init(opts), do: Keyword.get(opts, :role, :member)

  @impl true
  def call(conn, role) do
    with {:ok, bill_id} <- parse(conn.params["id"]),
         group_id when is_integer(group_id) <- Groups.group_id_for(:bill, bill_id),
         {:ok, member} <- Groups.authorize(conn.assigns.current_scope, group_id, role) do
      conn
      |> Plug.Conn.assign(:member, member)
      |> Plug.Conn.assign(:group_id, group_id)
      |> Plug.Conn.assign(:bill_id, bill_id)
    else
      {:error, reason} -> halt_with(conn, reason)
      nil -> halt_with(conn, :not_found)
    end
  end

  defp halt_with(conn, reason),
    do: conn |> FallbackController.call({:error, reason}) |> Plug.Conn.halt()

  defp parse(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp parse(_), do: {:error, :not_found}
end
