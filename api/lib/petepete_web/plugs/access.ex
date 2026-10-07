defmodule PetepeteWeb.Plugs.Access do
  @moduledoc """
  What the `GroupAccess`, `SessionAccess`, `BillAccess` and `TxnAccess` plugs share, once
  they know the group: authorize the caller there and assign the result.

    * role `:member`: `Groups.Policy.authorize/3`; assigns `:member` (the caller's `Member`).
    * role `:host`: `Groups.Policy.authorize_actor/3`; assigns `:actor` (a host `Petepete.Actor`,
      what host actions hand to contexts) and `:member`, for controllers that still read the
      roster entry.

  Both also assign `:group_id`. Unknown group or non-member halts with 404, a non-host
  member on a host route with 403 (`PetepeteWeb.FallbackController`).
  """
  alias Petepete.Groups.Policy, as: GroupsPolicy
  alias PetepeteWeb.FallbackController

  @spec authorize(Plug.Conn.t(), integer() | nil, :member | :host) :: Plug.Conn.t()
  def authorize(conn, group_id, role) do
    case do_authorize(conn.assigns.current_scope, group_id, role) do
      {:ok, assigns} ->
        Enum.reduce([group_id: group_id] ++ assigns, conn, fn {k, v}, c ->
          Plug.Conn.assign(c, k, v)
        end)

      {:error, reason} ->
        halt_with(conn, reason)
    end
  end

  @spec halt_with(Plug.Conn.t(), :not_found | :forbidden) :: Plug.Conn.t()
  def halt_with(conn, reason),
    do: conn |> FallbackController.call({:error, reason}) |> Plug.Conn.halt()

  @doc "Parses a path param holding an integer id; anything else is `{:error, :not_found}`."
  @spec parse_id(term()) :: {:ok, integer()} | {:error, :not_found}
  def parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  def parse_id(_), do: {:error, :not_found}

  defp do_authorize(scope, group_id, :member) do
    with {:ok, member} <- GroupsPolicy.authorize(scope, group_id, :member),
         do: {:ok, member: member}
  end

  defp do_authorize(scope, group_id, :host) do
    with {:ok, actor} <- GroupsPolicy.authorize_actor(scope, group_id, :host),
         {:ok, member} <- GroupsPolicy.authorize(scope, group_id, :member) do
      {:ok, actor: actor, member: member}
    end
  end
end
