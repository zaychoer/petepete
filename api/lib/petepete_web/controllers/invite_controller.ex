defmodule PetepeteWeb.InviteController do
  @moduledoc """
  Joining a group by invite token. The only write open to people without an account:
  the web join page calls it unauthenticated, the app calls it with a bearer token.

  `GET /api/invites/:token` answers `{group_name}` and nothing else (no members, no host,
  no phone numbers), so the join page can name the group before asking for a name.
  """
  use PetepeteWeb, :controller

  alias Petepete.Groups

  action_fallback PetepeteWeb.FallbackController

  def show(conn, %{"token" => token}) do
    with {:ok, group_name} <- Groups.invite_group_name(token) do
      json(conn, %{group_name: group_name})
    end
  end

  def join(conn, %{"token" => token} = params) do
    with {:ok, %{group: group, member: member, created: created}} <-
           Groups.join(token, params, conn.assigns.current_scope) do
      conn
      |> put_status(if(created, do: 201, else: 200))
      |> json(%{
        member_id: member.id,
        group: %{id: group.id, name: group.name},
        claim: claim_hint(member)
      })
    end
  end

  # A joiner without an account can later claim their entry from the app.
  defp claim_hint(%{user_id: nil, id: id}),
    do: %{claimable: true, path: "/api/members/#{id}/claim"}

  defp claim_hint(_member), do: %{claimable: false}
end
