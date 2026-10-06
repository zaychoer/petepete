defmodule PetepeteWeb.InviteController do
  @moduledoc """
  Joining a group by invite token. The only write open to people without an account:
  the web join page calls it unauthenticated, the app calls it with a bearer token.

  `GET /api/invites/:token` answers `{group_name}` and nothing else (no members, no host,
  no phone numbers), so the join page can name the group before asking for a name.

  An unknown or reset token is 404 `invite_not_found` (not the generic `not_found`), whose
  message tells the person to ask the host for a new link.
  """
  use PetepeteWeb, :controller

  alias Petepete.Groups
  alias PetepeteWeb.FallbackController

  action_fallback PetepeteWeb.FallbackController

  def show(conn, %{"token" => token}) do
    with {:ok, group_name} <- Groups.invite_group_name(token) do
      json(conn, %{group_name: group_name})
    else
      other -> failed(conn, other)
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
    else
      other -> failed(conn, other)
    end
  end

  defp failed(conn, {:error, :not_found}),
    do: FallbackController.respond(conn, 404, "invite_not_found")

  defp failed(conn, {:error, _} = error), do: FallbackController.call(conn, error)

  # A joiner without an account can later claim their entry from the app.
  defp claim_hint(%{user_id: nil, id: id}),
    do: %{claimable: true, path: "/api/members/#{id}/claim"}

  defp claim_hint(_member), do: %{claimable: false}
end
