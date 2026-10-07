defmodule PetepeteWeb.Plugs.GroupAccessTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures

  alias Petepete.Accounts.Scope
  alias PetepeteWeb.Plugs.GroupAccess

  defp run(user, group_id, role) do
    build_conn(:get, "/", %{"group_id" => to_string(group_id)})
    |> Plug.Conn.fetch_query_params()
    |> assign(:current_scope, Scope.for(user))
    |> GroupAccess.call(GroupAccess.init(role: role))
  end

  setup do
    a = group_fixture()
    b = group_fixture()
    {host, host_member} = host_fixture(a)
    {plain, _} = plain_member_fixture(a)
    %{a: a, b: b, host: host, host_member: host_member, plain: plain}
  end

  test "a host route assigns the host Actor, the member and the group", ctx do
    conn = run(ctx.host, ctx.a.id, :host)
    refute conn.halted
    assert conn.assigns.member.id == ctx.host_member.id
    assert conn.assigns.group_id == ctx.a.id

    assert conn.assigns.actor ==
             %Petepete.Actor{type: :host, user_id: ctx.host.id, member_id: ctx.host_member.id}
  end

  test "a member route assigns the member and no Actor", ctx do
    conn = run(ctx.plain, ctx.a.id, :member)
    refute conn.halted
    assert conn.assigns.member.role == "member"
    refute Map.has_key?(conn.assigns, :actor)
  end

  test "403 for a plain member on a host route", ctx do
    conn = run(ctx.plain, ctx.a.id, :host)
    assert conn.halted
    assert json_response(conn, 403) == %{"error" => "forbidden"}
  end

  test "404 for another group and for malformed ids", ctx do
    conn = run(ctx.host, ctx.b.id, :member)
    assert conn.halted
    assert json_response(conn, 404) == %{"error" => "not_found"}
    assert json_response(run(ctx.host, "abc", :member), 404) == %{"error" => "not_found"}
  end
end
