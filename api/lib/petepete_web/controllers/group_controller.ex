defmodule PetepeteWeb.GroupController do
  @moduledoc "Creating a group, its roster (including guests), the invite link and the caller's groups."
  use PetepeteWeb, :controller

  alias Petepete.Groups
  alias Petepete.Groups.Templates
  alias PetepeteWeb.Labels
  alias PetepeteWeb.Plugs.GroupAccess

  action_fallback PetepeteWeb.FallbackController

  plug GroupAccess, [role: :member] when action in [:show]
  plug GroupAccess, [role: :host] when action in [:reset_invite, :add_guest]

  def index(conn, _params) do
    groups =
      for %{group: group, member: member} <- Groups.list_groups(conn.assigns.current_scope) do
        %{id: group.id, name: group.name, template: group.template,
          role: member.role, role_label: Labels.role(member.role)}
      end

    json(conn, %{groups: groups})
  end

  def create(conn, params) do
    with {:ok, %{group: group, host: host}} <-
           Groups.create_group(conn.assigns.current_scope, params) do
      conn
      |> put_status(201)
      |> json(%{
        group_id: group.id,
        invite_url: Groups.invite_url(group),
        name: group.name,
        template: group.template,
        rounding_unit: group.rounding_unit,
        cost_categories: Templates.cost_categories(group.template),
        member_id: host.id
      })
    end
  end

  def show(conn, _params) do
    %{group: group, members: members, viewer: viewer} = Groups.get_group(conn.assigns.member)
    host? = viewer.role == "host"

    json(conn, %{
      id: group.id,
      name: group.name,
      template: group.template,
      rounding_unit: group.rounding_unit,
      cost_categories: Templates.cost_categories(group.template),
      invite_url: (host? && Groups.invite_url(group)) || nil,
      members: Enum.map(members, &member_json(&1, host?)),
      you: %{member_id: viewer.id, role: viewer.role, role_label: Labels.role(viewer.role)}
    })
  end

  def reset_invite(conn, _params) do
    with {:ok, group} <- Groups.reset_invite(conn.assigns.member) do
      json(conn, %{invite_url: Groups.invite_url(group)})
    end
  end

  def add_guest(conn, params) do
    with {:ok, guest} <- Groups.add_guest(conn.assigns.member, params) do
      conn |> put_status(201) |> json(%{member_id: guest.id})
    end
  end

  defp member_json(member, host?) do
    base = %{
      id: member.id,
      display_name: member.display_name,
      role: member.role,
      role_label: Labels.role(member.role),
      has_account: member.user_id != nil
    }

    if host? do
      Map.merge(base, %{
        phone: member.phone,
        pending_claim: member.claim_user && %{display_name: member.claim_user.display_name}
      })
    else
      base
    end
  end
end
