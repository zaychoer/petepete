defmodule PetepeteWeb.HomeControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures

  alias Petepete.Clock

  setup %{conn: conn} do
    # Tuesday 2026-10-06 10:00 WIB.
    Clock.freeze(~U[2026-10-06 03:00:00Z])

    group = group_fixture()
    other = group_fixture()

    host = user_fixture(%{phone: valid_phone()})
    host_member = member_fixture(group, role: "host", user: host)
    plain = user_fixture(%{phone: valid_phone()})
    plain_member = member_fixture(group, role: "member", user: plain)
    outsider = user_fixture(%{phone: valid_phone()})
    member_fixture(other, role: "host", user: outsider)

    event = event_fixture(group, %{name: "Futsal Kamis", type: "recurring"})
    next = session_fixture(event, %{starts_at: ~U[2026-10-08 12:00:00Z]})

    issued =
      session_fixture(event, %{
        starts_at: ~U[2026-10-01 12:00:00Z],
        status: "issued"
      })

    bill_fixture(issued, plain_member, %{amount_due: 25_000})
    bill_fixture(issued, host_member, %{amount_due: 25_000, status: "needs_review"})

    # The other group's data must never show up.
    other_event = event_fixture(other)
    session_fixture(other_event, %{starts_at: ~U[2026-10-07 12:00:00Z]})
    bill_fixture(session_fixture(other_event), member_fixture(other, role: "member"))

    %{conn: conn, group: group, host: host, plain: plain, outsider: outsider, next: next}
  end

  defp home(conn, user, group),
    do: conn |> bearer_conn(user) |> get(~p"/api/groups/#{group.id}/home")

  test "a plain member sees the next session card, kas and open bills of their group", ctx do
    body = home(ctx.conn, ctx.plain, ctx.group) |> json_response(200)

    assert %{
             "role" => "member",
             "group" => %{"name" => _},
             "kas_balance" => 0,
             "next_session" => %{
               "id" => id,
               "event_name" => "Futsal Kamis",
               "starts_at" => "2026-10-08T12:00:00Z",
               "progress" => "draft",
               "cost_total" => 0,
               "attended_count" => 0
             },
             "unpaid_bills" => [%{"amount_due" => 25_000, "status" => "unpaid"} = unpaid],
             "needs_review_bills" => [%{"status" => "needs_review"}]
           } = body

    assert id == ctx.next.id
    refute Map.has_key?(unpaid, "pay_token")
  end

  test "the host sees the same home", ctx do
    assert %{"role" => "host", "unpaid_bills" => [_]} =
             home(ctx.conn, ctx.host, ctx.group) |> json_response(200)
  end

  test "someone outside the group gets 404, and no token gets 401", ctx do
    assert %{"error" => "not_found"} =
             home(ctx.conn, ctx.outsider, ctx.group) |> json_response(404)

    assert %{"error" => "unauthenticated"} =
             ctx.conn |> get(~p"/api/groups/#{ctx.group.id}/home") |> json_response(401)
  end
end
