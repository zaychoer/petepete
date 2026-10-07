defmodule PetepeteWeb.Plugs.GroupAccess do
  @moduledoc """
  Authorizes the caller against the `group_id` path param.

      plug PetepeteWeb.Plugs.GroupAccess, role: :host

  On success assigns `conn.assigns.member`; otherwise halts with 404/403 JSON.
  Requires `conn.assigns.current_scope` (set by the `:authenticated` pipeline).
  """
  @behaviour Plug

  alias Petepete.Groups
  alias PetepeteWeb.FallbackController

  @impl true
  def init(opts), do: Keyword.get(opts, :role, :member)

  @impl true
  def call(conn, role) do
    with {:ok, group_id} <- parse(conn.params["group_id"]),
         {:ok, member} <- Groups.authorize(conn.assigns.current_scope, group_id, role) do
      Plug.Conn.assign(conn, :member, member)
    else
      {:error, reason} -> conn |> FallbackController.call({:error, reason}) |> Plug.Conn.halt()
    end
  end

  defp parse(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp parse(_), do: {:error, :not_found}
end
