defmodule PetepeteWeb.SessionControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures

  alias Petepete.Repo

  setup %{conn: conn} do
    a = group_fixture()
    b = group_fixture()
    {host_user, host} = host_fixture(a)
    {plain_user, plain} = plain_member_fixture(a)
    {other_user, _} = host_fixture(b)
    session = session_fixture(event_fixture(a))

    %{
      a: a,
      host: host,
      plain: plain,
      session: session,
      conn: put_req_header(conn, "accept", "application/json"),
      host_conn: log_in(conn, host_user),
      plain_conn: log_in(conn, plain_user),
      other_conn: log_in(conn, other_user)
    }
  end

  defp log_in(conn, user) do
    user
    |> Ecto.Changeset.change(phone: valid_phone())
    |> Repo.update!()
    |> then(&bearer_conn(conn, &1))
  end

  defp cost_path(session, cid), do: ~p"/api/sessions/#{session.id}/costs/#{cid}"

  test "every route needs a bearer token", %{conn: conn, session: session} do
    for conn <- [
          get(conn, ~p"/api/sessions/#{session.id}"),
          put(conn, cost_path(session, "new"), %{}),
          delete(conn, cost_path(session, 1)),
          put(conn, ~p"/api/sessions/#{session.id}/attendance", %{})
        ] do
      assert %{"error" => "unauthenticated"} = json_response(conn, 401)
    end
  end

  test "spec example 'Pos subset': 10 attend, three costs, the drink is borne by its 6 only",
       %{host_conn: conn, session: session, a: a, host: host} do
    members = [host | for(_ <- 1..9, do: member_fixture(a, role: "member"))]
    drinkers = members |> Enum.take(6) |> Enum.map(& &1.id)

    for m <- members do
      conn =
        put(conn, ~p"/api/sessions/#{session.id}/attendance", %{member_id: m.id, attended: true})

      assert %{"participant" => %{"attended" => true, "weight" => 1000}} =
               json_response(conn, 200)
    end

    for {category, amount, extra} <- [
          {"lapangan", 350_000, %{}},
          {"wasit", 100_000, %{}},
          {"minum", 60_000, %{scope: "subset", members: drinkers}}
        ] do
      conn =
        put(
          conn,
          cost_path(session, "new"),
          Map.merge(%{category: category, amount: amount}, extra)
        )

      assert %{"cost_item" => %{"id" => _}} = json_response(conn, 201)
    end

    assert %{"cost_items" => [lapangan, wasit, minum], "participants" => participants} =
             get(conn, ~p"/api/sessions/#{session.id}") |> json_response(200)

    all_ids = members |> Enum.map(& &1.id) |> Enum.sort()
    assert length(participants) == 10
    assert %{"amount" => 350_000, "scope" => "all", "bearer_ids" => ^all_ids} = lapangan
    assert %{"amount" => 100_000, "bearer_ids" => ^all_ids} = wasit

    assert %{"amount" => 60_000, "scope" => "subset", "members" => m, "bearer_ids" => b} = minum
    assert Enum.sort(m) == Enum.sort(drinkers)
    assert Enum.sort(b) == Enum.sort(drinkers)
    assert length(b) == 6

    # Two of the six drinkers leave: they still are in the subset but no longer bear the item.
    for id <- Enum.take(drinkers, -2) do
      put(conn, ~p"/api/sessions/#{session.id}/attendance", %{member_id: id, attended: false})
    end

    assert %{"cost_items" => [_, _, %{"members" => m2, "bearer_ids" => b2}]} =
             get(conn, ~p"/api/sessions/#{session.id}") |> json_response(200)

    assert length(m2) == 6
    assert Enum.sort(b2) == Enum.sort(Enum.take(drinkers, 4))
  end

  test "cost item payload shows the payer; default host, changeable, 'new' vs existing id",
       %{host_conn: conn, session: session, host: host, plain: plain} do
    assert %{"cost_item" => %{"id" => id, "paid_by" => paid_by, "paid_by_name" => name}} =
             put(conn, cost_path(session, "new"), %{category: "lapangan", amount: 350_000})
             |> json_response(201)

    assert paid_by == host.id
    assert name == host.display_name

    assert %{"cost_item" => %{"id" => ^id, "paid_by" => pid, "paid_by_name" => pname}} =
             put(conn, cost_path(session, id), %{
               category: "lapangan",
               amount: 350_000,
               paid_by: plain.id
             })
             |> json_response(200)

    assert pid == plain.id
    assert pname == plain.display_name

    assert put(conn, cost_path(session, 0), %{category: "x", amount: 1}).status == 404
    assert put(conn, cost_path(session, "abc"), %{category: "x", amount: 1}).status == 404
    assert delete(conn, cost_path(session, id)).status == 204

    assert %{"cost_items" => []} =
             get(conn, ~p"/api/sessions/#{session.id}") |> json_response(200)
  end

  test "422 lists field errors; weight 0 is rejected", %{
    host_conn: conn,
    session: session,
    plain: plain
  } do
    assert %{"error" => "invalid", "errors" => %{"amount" => [_]}} =
             put(conn, cost_path(session, "new"), %{category: "lapangan", amount: 0})
             |> json_response(422)

    assert %{"error" => "invalid", "errors" => %{"amount" => ["is invalid"]}} =
             put(conn, cost_path(session, "new"), %{category: "lapangan", amount: 1000.5})
             |> json_response(422)

    assert %{"errors" => %{"weight" => [_]}} =
             put(conn, ~p"/api/sessions/#{session.id}/attendance", %{
               member_id: plain.id,
               attended: true,
               weight: 0
             })
             |> json_response(422)
  end

  test "a plain member may read but never write; the other group's host sees nothing", ctx do
    %{session: session, plain: plain} = ctx

    assert get(ctx.plain_conn, ~p"/api/sessions/#{session.id}").status == 200

    assert put(ctx.plain_conn, cost_path(session, "new"), %{category: "x", amount: 1}).status ==
             403

    assert delete(ctx.plain_conn, cost_path(session, 1)).status == 403

    assert put(ctx.plain_conn, ~p"/api/sessions/#{session.id}/attendance", %{
             member_id: plain.id,
             attended: true
           }).status ==
             403

    assert %{"error" => "not_found"} =
             json_response(get(ctx.other_conn, ~p"/api/sessions/#{session.id}"), 404)

    assert put(ctx.other_conn, cost_path(session, "new"), %{category: "x", amount: 1}).status ==
             404

    assert delete(ctx.other_conn, cost_path(session, 1)).status == 404

    assert put(ctx.other_conn, ~p"/api/sessions/#{session.id}/attendance", %{
             member_id: plain.id,
             attended: true
           }).status ==
             404
  end

  test "authorization comes before the status: outsiders never learn it, nothing changes", ctx do
    %{session: session, plain: plain} = ctx
    session |> Ecto.Changeset.change(status: "issued") |> Repo.update!()

    for {conn, status} <- [{ctx.plain_conn, 403}, {ctx.other_conn, 404}] do
      assert put(conn, cost_path(session, "new"), %{category: "x", amount: 1}).status == status
      assert put(conn, cost_path(session, 1), %{category: "x", amount: 1}).status == status
      assert delete(conn, cost_path(session, 1)).status == status

      assert put(conn, ~p"/api/sessions/#{session.id}/attendance", %{
               member_id: plain.id,
               attended: true
             }).status == status
    end

    assert Petepete.Billing.list_cost_items(session.id) == []
    assert Petepete.Billing.list_participants(session.id) == []
  end

  test "an unknown session is 404 on every route", %{host_conn: conn} do
    assert get(conn, ~p"/api/sessions/0").status == 404
    assert put(conn, ~p"/api/sessions/0/costs/new", %{category: "x", amount: 1}).status == 404
    assert put(conn, ~p"/api/sessions/0/costs/1", %{category: "x", amount: 1}).status == 404
    assert delete(conn, ~p"/api/sessions/0/costs/1").status == 404

    assert put(conn, ~p"/api/sessions/0/attendance", %{member_id: 1, attended: true}).status ==
             404
  end

  test "an issued session answers 409 with its status until it is a draft again",
       %{host_conn: conn, session: session, plain: plain} do
    session |> Ecto.Changeset.change(status: "issued") |> Repo.update!()

    assert %{"error" => "session_not_editable", "status" => "issued"} =
             put(conn, cost_path(session, "new"), %{category: "x", amount: 1})
             |> json_response(409)

    assert put(conn, ~p"/api/sessions/#{session.id}/attendance", %{
             member_id: plain.id,
             attended: true
           }).status ==
             409

    assert %{"session" => %{"status" => "issued", "progress" => "issued"}} =
             get(conn, ~p"/api/sessions/#{session.id}") |> json_response(200)

    Repo.get!(Petepete.Billing.Session, session.id)
    |> Ecto.Changeset.change(status: "draft")
    |> Repo.update!()

    assert put(conn, cost_path(session, "new"), %{category: "x", amount: 1}).status == 201
  end
end
