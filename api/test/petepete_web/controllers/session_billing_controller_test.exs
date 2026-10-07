defmodule PetepeteWeb.SessionBillingControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures

  alias Petepete.{Clock, Ledger, Repo}

  setup do
    Clock.freeze(~U[2026-10-06 03:00:00Z])
    :ok
  end

  # A group whose host is `user`, with a draft session of 3 attendees and a Rp100.000 cost.
  defp group_with_session(user, role \\ "host") do
    group = group_fixture()
    host = member_fixture(group, role: role, user: user)
    others = for _ <- 1..2, do: member_fixture(group, role: "member")
    session = session_fixture(event_fixture(group))
    for m <- [host | others], do: attendance_fixture(session, m)
    cost_item_fixture(session, amount: 100_000, paid_by: host)
    %{group: group, host: host, others: others, session: session}
  end

  setup %{conn: conn} do
    {conn, user} = bearer_login(conn)
    %{conn: conn, user: user}
  end

  describe "GET /api/sessions/:id/preview" do
    test "returns the breakdown the preview screen needs", %{conn: conn, user: user} do
      ctx = group_with_session(user)

      body = conn |> get(~p"/api/sessions/#{ctx.session.id}/preview") |> json_response(200)

      assert %{
               "total_cost" => 100_000,
               "total_billed" => 102_000,
               "kas_remainder" => 2_000,
               "credit_used" => 34_000,
               "total_due" => 68_000,
               "rounding_unit" => 1000
             } = body

      assert [%{"amount" => 100_000, "paid_by_member_id" => _}] = body["items"]
      assert [%{"member_id" => _, "amount" => _} | _] = body["fronted"]

      host = Enum.find(body["members"], &(&1["member_id"] == ctx.host.id))

      assert %{
               "share" => 34_000,
               "credit_applied" => 34_000,
               "amount_due" => 0,
               "raw_share" => %{"numerator" => 100_000, "denominator" => 3},
               "lines" => [%{"fraction" => %{"numerator" => 100_000, "denominator" => 3}}]
             } = host
    end

    test "a host of another group gets 404 and a plain member 403", %{conn: conn, user: user} do
      ctx = group_with_session(user)
      other = group_with_session(user_fixture())
      {member_conn, member_user} = bearer_login(build_conn())
      member_fixture(ctx.group, role: "member", user: member_user)
      {stranger_conn, _} = bearer_login(build_conn())

      assert get(member_conn, ~p"/api/sessions/#{ctx.session.id}/preview")
             |> json_response(403) == %{"error" => "forbidden"}

      assert get(stranger_conn, ~p"/api/sessions/#{ctx.session.id}/preview")
             |> json_response(404) == %{"error" => "not_found"}

      assert get(conn, ~p"/api/sessions/#{other.session.id}/preview")
             |> json_response(404) == %{"error" => "not_found"}

      assert get(conn, ~p"/api/sessions/0/preview") |> json_response(404)
    end

    test "needs a token" do
      assert build_conn() |> get(~p"/api/sessions/1/preview") |> json_response(401)
    end

    test "an unbillable session is 422 with the problems", %{conn: conn, user: user} do
      ctx = group_with_session(user)
      Repo.update_all(Petepete.Billing.Participant, set: [attended: false])

      assert %{"error" => "invalid_session", "problems" => [%{"code" => "item_without_bearers"}]} =
               conn |> get(~p"/api/sessions/#{ctx.session.id}/preview") |> json_response(422)
    end
  end

  describe "POST /api/sessions/:id/issue" do
    defp issue(conn, session_id, key) do
      conn
      |> put_req_header("idempotency-key", key)
      |> post(~p"/api/sessions/#{session_id}/issue")
    end

    test "issues bills and returns them with the txn id", %{conn: conn, user: user} do
      ctx = group_with_session(user)

      body = issue(conn, ctx.session.id, "key-1") |> json_response(200)

      assert %{"replayed" => false, "txn_id" => txn_id, "bills" => bills} = body
      assert [%{id: ^txn_id}] = Ledger.txns(ctx.group.id)
      assert length(bills) == 3

      host = Enum.find(bills, &(&1["member_id"] == ctx.host.id))
      assert %{"status" => "paid", "amount_due" => 0, "credit_applied" => 34_000} = host

      other = Enum.find(bills, &(&1["member_id"] == hd(ctx.others).id))
      assert %{"status" => "unpaid", "amount_due" => 34_000, "pay_token" => token} = other
      assert byte_size(token) >= 22
    end

    test "a repeated request posts one txn and returns the same bills", %{conn: conn, user: user} do
      ctx = group_with_session(user)

      first = issue(conn, ctx.session.id, "dup") |> json_response(200)
      second = issue(conn, ctx.session.id, "dup") |> json_response(200)

      assert second["replayed"] == true
      assert second["txn_id"] == first["txn_id"]
      assert second["bills"] == first["bills"]
      assert length(Ledger.txns(ctx.group.id)) == 1
    end

    test "a different key after issuing is 409, no header is 422", %{conn: conn, user: user} do
      ctx = group_with_session(user)
      issue(conn, ctx.session.id, "one") |> json_response(200)

      assert %{"error" => "invalid_transition", "entity" => "session", "status" => "issued"} =
               issue(conn, ctx.session.id, "two") |> json_response(409)

      assert %{"error" => "idempotency_key_required"} =
               post(conn, ~p"/api/sessions/#{ctx.session.id}/issue") |> json_response(422)

      assert length(Ledger.txns(ctx.group.id)) == 1
    end

    test "only the host of the session's group may issue", %{user: user} do
      ctx = group_with_session(user)
      {member_conn, member_user} = bearer_login(build_conn())
      member_fixture(ctx.group, role: "member", user: member_user)
      {stranger_conn, _} = bearer_login(build_conn())

      assert issue(member_conn, ctx.session.id, "m") |> json_response(403)
      assert issue(stranger_conn, ctx.session.id, "s") |> json_response(404)

      assert build_conn()
             |> put_req_header("idempotency-key", "x")
             |> post(~p"/api/sessions/#{ctx.session.id}/issue")
             |> json_response(401)

      assert Ledger.txns(ctx.group.id) == []
      assert Repo.get!(Petepete.Billing.Session, ctx.session.id).status == "draft"
    end

    test "a host of group B cannot issue group A's session even with a valid token", %{
      conn: conn,
      user: user
    } do
      a = group_with_session(user_fixture())
      _b = group_with_session(user)

      assert issue(conn, a.session.id, "k") |> json_response(404)
      assert Ledger.txns(a.group.id) == []
    end
  end
end
