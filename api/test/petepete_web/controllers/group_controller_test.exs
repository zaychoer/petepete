defmodule PetepeteWeb.GroupControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures

  alias Petepete.Groups.{Group, Member, Templates}
  alias Petepete.{Contract, Repo}

  describe "POST /api/groups" do
    test "creates the group from its template, with the caller as host and Rp1.000 rounding", %{
      conn: conn
    } do
      {conn, user} = bearer_login(conn)

      created = post(conn, ~p"/api/groups", %{name: "Futsal Kamis", template: "Futsal"})
      body = json_response(created, 201)
      Contract.check!("group_created.ok", created)

      assert %{"group_id" => id, "invite_url" => url, "member_id" => member_id} = body
      assert body["rounding_unit"] == 1000
      assert body["cost_categories"] == Templates.cost_categories("Futsal")

      group = Repo.get!(Group, id)
      assert %{name: "Futsal Kamis", template: "Futsal", rounding_unit: 1000} = group
      assert url == "https://petepete.test/join/" <> group.invite_token

      assert %Member{role: "host", user_id: user_id, group_id: ^id} = Repo.get!(Member, member_id)
      assert user_id == user.id
    end

    test "every template is accepted and exposes its own categories", %{conn: conn} do
      {conn, _} = bearer_login(conn)

      for template <- Templates.names() do
        body = post(conn, ~p"/api/groups", %{name: "G", template: template}) |> json_response(201)
        assert body["cost_categories"] == Templates.cost_categories(template)
      end
    end

    test "invite tokens are url-safe and at least 128 bits", %{conn: conn} do
      {conn, _} = bearer_login(conn)
      post(conn, ~p"/api/groups", %{name: "G", template: "Padel"}) |> json_response(201)

      token = Repo.one!(Group).invite_token
      assert token =~ ~r/\A[A-Za-z0-9_-]+\z/
      assert byte_size(Base.url_decode64!(token, padding: false)) >= 16
    end

    test "rejects a missing name and an unknown template", %{conn: conn} do
      {conn, _} = bearer_login(conn)

      invalid = post(conn, ~p"/api/groups", %{name: "  ", template: "Futsal"})
      assert %{"error" => "invalid", "fields" => %{"name" => _}} = json_response(invalid, 422)
      Contract.check!("errors/invalid", invalid)

      assert %{"error" => "invalid", "fields" => %{"template" => _}} =
               post(conn, ~p"/api/groups", %{name: "G", template: "Catur"}) |> json_response(422)

      assert %{"error" => "invalid", "fields" => %{"template" => _}} =
               post(conn, ~p"/api/groups", %{name: "G"}) |> json_response(422)

      assert Repo.aggregate(Group, :count) == 0
    end

    test "needs a login", %{conn: conn} do
      conn = post(conn, ~p"/api/groups", %{name: "G", template: "Futsal"})
      assert %{"error" => "unauthenticated"} = json_response(conn, 401)
    end
  end

  describe "GET /api/groups" do
    test "lists only the caller's groups with the caller's role", %{conn: conn} do
      {conn, user} = bearer_login(conn)
      mine = group_fixture(%{name: "Mine", template: "Padel"})
      joined = group_fixture(%{name: "Joined"})
      other = group_fixture(%{name: "Other"})
      member_fixture(mine, role: "host", user: user)
      member_fixture(joined, role: "member", user: user)
      member_fixture(other, role: "host", user: user_fixture())

      listed = get(conn, ~p"/api/groups")
      assert %{"groups" => groups} = json_response(listed, 200)
      Contract.check!("group_list.groups", listed)

      assert groups == [
               %{
                 "id" => mine.id,
                 "name" => "Mine",
                 "template" => "Padel",
                 "role" => "host",
                 "role_label" => "Host"
               },
               %{
                 "id" => joined.id,
                 "name" => "Joined",
                 "template" => nil,
                 "role" => "member",
                 "role_label" => "Anggota"
               }
             ]
    end
  end

  describe "GET /api/groups/:id" do
    setup %{conn: conn} do
      {conn, user} = bearer_login(conn)
      group = group_fixture(%{name: "Badminton Jumat", template: "Badminton"})
      host = member_fixture(group, role: "host", user: user)
      %{conn: conn, user: user, group: group, host: host}
    end

    test "a host sees name, rounding, template, roster with roles, phones and the invite link",
         ctx do
      guest = member_fixture(ctx.group, role: "guest")
      shown = get(ctx.conn, ~p"/api/groups/#{ctx.group.id}")
      body = json_response(shown, 200)
      Contract.check!("group_detail.host", shown)

      assert %{"name" => "Badminton Jumat", "rounding_unit" => 1000, "template" => "Badminton"} =
               body

      assert body["cost_categories"] == Templates.cost_categories("Badminton")
      assert body["invite_url"] == "https://petepete.test/join/" <> ctx.group.invite_token

      assert body["you"] == %{
               "member_id" => ctx.host.id,
               "role" => "host",
               "role_label" => "Host"
             }

      assert [%{"id" => hid, "role" => "host", "phone" => _}, %{"id" => gid, "role" => "guest"}] =
               body["members"]

      assert {hid, gid} == {ctx.host.id, guest.id}
    end

    test "a plain member sees the roster by name and role but no phones, claims or invite link",
         ctx do
      {conn, user} = bearer_login(build_conn())
      member_fixture(ctx.group, role: "member", user: user)
      guest = member_fixture(ctx.group, role: "guest")
      Repo.update!(Ecto.Changeset.change(guest, phone: "628123456789"))

      shown = get(conn, ~p"/api/groups/#{ctx.group.id}")
      body = json_response(shown, 200)
      Contract.check!("group_detail.member", shown)

      assert body["invite_url"] == nil
      assert length(body["members"]) == 3

      for member <- body["members"] do
        assert Map.keys(member) |> Enum.sort() == [
                 "display_name",
                 "has_account",
                 "id",
                 "role",
                 "role_label"
               ]
      end
    end

    test "someone outside the group gets 404, as for a group that does not exist", ctx do
      {outsider, _} = bearer_login(build_conn())

      not_found = get(outsider, ~p"/api/groups/#{ctx.group.id}")
      assert %{"error" => "not_found"} = json_response(not_found, 404)
      Contract.check!("errors/not_found", not_found)

      assert %{"error" => "not_found"} = json_response(get(outsider, ~p"/api/groups/0"), 404)
    end
  end

  describe "POST /api/groups/:id/guests" do
    setup %{conn: conn} do
      {conn, user} = bearer_login(conn)
      group = group_fixture()
      member_fixture(group, role: "host", user: user)
      %{conn: conn, group: group}
    end

    test "a guest needs only a name and shows up in the roster for later sessions", ctx do
      added = post(ctx.conn, ~p"/api/groups/#{ctx.group.id}/guests", %{name: "Om Budi"})
      assert %{"member_id" => id} = json_response(added, 201)
      Contract.check!("guest.created", added)

      assert %Member{role: "guest", display_name: "Om Budi", phone: nil, user_id: nil} =
               Repo.get!(Member, id)

      roster =
        get(ctx.conn, ~p"/api/groups/#{ctx.group.id}")
        |> json_response(200)
        |> Map.fetch!("members")

      assert %{"role" => "guest", "display_name" => "Om Budi"} =
               Enum.find(roster, &(&1["id"] == id))
    end

    test "a phone number is optional and normalised when given", ctx do
      assert %{"member_id" => id} =
               post(ctx.conn, ~p"/api/groups/#{ctx.group.id}/guests", %{
                 name: "Tamu",
                 phone: "0812-3456-7890"
               })
               |> json_response(201)

      assert Repo.get!(Member, id).phone == "6281234567890"

      assert %{"fields" => %{"phone" => _}} =
               post(ctx.conn, ~p"/api/groups/#{ctx.group.id}/guests", %{
                 name: "Tamu",
                 phone: "123"
               })
               |> json_response(422)
    end

    test "a name is required", ctx do
      assert %{"fields" => %{"name" => _}} =
               post(ctx.conn, ~p"/api/groups/#{ctx.group.id}/guests", %{phone: "081234567890"})
               |> json_response(422)
    end

    test "only the host adds guests; other groups' hosts see 404", ctx do
      {member_conn, user} = bearer_login(build_conn())
      member_fixture(ctx.group, role: "member", user: user)
      {other_host, other_user} = bearer_login(build_conn())
      member_fixture(group_fixture(), role: "host", user: other_user)

      path = ~p"/api/groups/#{ctx.group.id}/guests"

      forbidden = post(member_conn, path, %{name: "X"})
      assert %{"error" => "forbidden"} = json_response(forbidden, 403)
      Contract.check!("errors/forbidden", forbidden)

      assert %{"error" => "not_found"} = json_response(post(other_host, path, %{name: "X"}), 404)
      assert Repo.aggregate(Member, :count) == 3
    end
  end

  describe "POST /api/groups/:id/invite/reset" do
    test "gives a new link, and only the host may", %{conn: conn} do
      {host_conn, host} = bearer_login(conn)
      {member_conn, member} = bearer_login(build_conn())
      group = group_fixture()
      member_fixture(group, role: "host", user: host)
      member_fixture(group, role: "member", user: member)
      old_url = "https://petepete.test/join/" <> group.invite_token

      path = ~p"/api/groups/#{group.id}/invite/reset"
      assert %{"error" => "forbidden"} = json_response(post(member_conn, path), 403)
      assert Repo.get!(Group, group.id).invite_token == group.invite_token

      reset = post(host_conn, path)
      assert %{"invite_url" => new_url} = json_response(reset, 200)
      Contract.check!("invite_reset.ok", reset)
      assert new_url != old_url
      assert new_url == "https://petepete.test/join/" <> Repo.get!(Group, group.id).invite_token
    end

    test "another group's host gets 404 and the token stays", %{conn: conn} do
      {conn, user} = bearer_login(conn)
      member_fixture(group_fixture(), role: "host", user: user)
      group = group_fixture()

      assert %{"error" => "not_found"} =
               json_response(post(conn, ~p"/api/groups/#{group.id}/invite/reset"), 404)

      assert Repo.get!(Group, group.id).invite_token == group.invite_token
    end
  end
end
