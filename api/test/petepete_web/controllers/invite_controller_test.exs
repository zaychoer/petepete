defmodule PetepeteWeb.InviteControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Ecto.Query
  import Petepete.Fixtures

  alias Petepete.Groups.{Group, Member}
  alias Petepete.{Contract, Repo}

  setup do
    group = group_fixture(%{name: "Futsal Kamis"})
    host_fixture(group)
    %{group: group}
  end

  defp join_path(token), do: ~p"/api/invites/#{token}/join"

  describe "joining without a login (web)" do
    test "adds a roster entry without an account and hints how to claim it", %{
      conn: conn,
      group: group
    } do
      joined =
        post(conn, join_path(group.invite_token), %{
          display_name: "  Andi ",
          phone: "0812 3456 7890"
        })

      body = json_response(joined, 201)
      Contract.check!("invite_join.anonymous", joined)

      assert %{"member_id" => id, "group" => %{"id" => gid, "name" => "Futsal Kamis"}} = body
      assert gid == group.id
      assert body["claim"] == %{"claimable" => true, "path" => "/api/members/#{id}/claim"}

      assert %Member{
               role: "member",
               user_id: nil,
               display_name: "Andi",
               phone: "6281234567890",
               group_id: ^gid
             } =
               Repo.get!(Member, id)
    end

    test "the phone is optional but the name is not", %{conn: conn, group: group} do
      assert %{"member_id" => _} =
               post(conn, join_path(group.invite_token), %{display_name: "Budi"})
               |> json_response(201)

      invalid = post(conn, join_path(group.invite_token), %{phone: "081234567890"})
      assert %{"fields" => %{"display_name" => _}} = json_response(invalid, 422)

      assert %{"fields" => %{"phone" => _}} =
               post(conn, join_path(group.invite_token), %{display_name: "Budi", phone: "12"})
               |> json_response(422)
    end

    test "never makes the joiner a host or guest, whatever the body says", %{
      conn: conn,
      group: group
    } do
      %{"member_id" => id} =
        post(conn, join_path(group.invite_token), %{
          display_name: "Sok Host",
          role: "host",
          user_id: 1
        })
        |> json_response(201)

      assert %Member{role: "member", user_id: nil} = Repo.get!(Member, id)
    end
  end

  describe "joining with a login (app)" do
    test "links the entry to the caller's account and phone", %{conn: conn, group: group} do
      {conn, user} = bearer_login(conn)

      joined =
        post(conn, join_path(group.invite_token), %{display_name: "Citra", phone: "081200000000"})

      body = json_response(joined, 201)
      Contract.check!("invite_join.account", joined)
      assert body["claim"] == %{"claimable" => false}
      member = Repo.get!(Member, body["member_id"])
      assert member.user_id == user.id
      assert member.phone == user.phone
    end

    test "joining twice returns the same entry", %{conn: conn, group: group} do
      {conn, _user} = bearer_login(conn)

      %{"member_id" => id} =
        post(conn, join_path(group.invite_token), %{display_name: "Citra"}) |> json_response(201)

      assert %{"member_id" => ^id} =
               post(conn, join_path(group.invite_token), %{display_name: "Lain"})
               |> json_response(200)

      assert Repo.aggregate(from(m in Member, where: m.group_id == ^group.id), :count) == 2
    end

    test "a bad token in the header is 401, not an anonymous join", %{conn: conn, group: group} do
      conn = put_req_header(conn, "authorization", "Bearer garbage")

      assert %{"error" => "unauthenticated"} =
               json_response(post(conn, join_path(group.invite_token), %{display_name: "X"}), 401)

      assert Repo.aggregate(from(m in Member, where: m.group_id == ^group.id), :count) == 1
    end
  end

  describe "looking up an invite" do
    test "shows only the group name, with no login", %{conn: conn, group: group} do
      shown = get(conn, ~p"/api/invites/#{group.invite_token}")
      assert json_response(shown, 200) == %{"group_name" => "Futsal Kamis"}
      Contract.check!("invite.preview", shown)
    end

    test "an unknown or reset token is 404", %{conn: conn, group: group} do
      unknown = get(conn, ~p"/api/invites/nope")
      assert %{"error" => "not_found"} = json_response(unknown, 404)
      Contract.check!("errors/not_found", unknown)

      {host_conn, host_user} = bearer_login(build_conn())
      member_fixture(group, role: "host", user: host_user)
      post(host_conn, ~p"/api/groups/#{group.id}/invite/reset") |> json_response(200)

      assert %{"error" => "not_found"} =
               json_response(get(conn, ~p"/api/invites/#{group.invite_token}"), 404)
    end
  end

  describe "invite tokens" do
    test "an unknown token is 404 and creates nothing", %{conn: conn} do
      before = Repo.aggregate(Member, :count)

      assert %{"error" => "not_found"} =
               json_response(post(conn, join_path("nope"), %{display_name: "X"}), 404)

      assert Repo.aggregate(Member, :count) == before
    end

    test "resetting the token invalidates the old link and the new one works", %{
      conn: conn,
      group: group
    } do
      old = group.invite_token

      assert %{"member_id" => _} =
               post(conn, join_path(old), %{display_name: "Sebelum"}) |> json_response(201)

      {host_conn, host_user} = bearer_login(build_conn())
      member_fixture(group, role: "host", user: host_user)

      reset = post(host_conn, ~p"/api/groups/#{group.id}/invite/reset")
      %{"invite_url" => url} = json_response(reset, 200)
      Contract.check!("invite_reset.ok", reset)

      new = String.replace_prefix(url, "https://petepete.test/join/", "")
      assert new != old

      assert %{"error" => "not_found"} =
               json_response(post(conn, join_path(old), %{display_name: "Sesudah"}), 404)

      assert %{"member_id" => _} =
               post(conn, join_path(new), %{display_name: "Sesudah"}) |> json_response(201)

      assert Repo.get!(Group, group.id).invite_token == new
    end
  end
end
