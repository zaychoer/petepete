defmodule PetepeteWeb.EventControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures

  alias Petepete.Billing.Session
  alias Petepete.{Contract, Repo}
  alias Petepete.Sessions.Event

  setup %{conn: conn} do
    group = group_fixture()
    other = group_fixture()

    host = user_fixture(%{phone: valid_phone()})
    member_fixture(group, role: "host", user: host)
    plain = user_fixture(%{phone: valid_phone()})
    member_fixture(group, role: "member", user: plain)
    outsider_host = user_fixture(%{phone: valid_phone()})
    member_fixture(other, role: "host", user: outsider_host)

    %{conn: conn, group: group, other: other, host: host, plain: plain, outsider: outsider_host}
  end

  defp create(conn, user, group, params),
    do: conn |> bearer_conn(user) |> post(~p"/api/groups/#{group.id}/events", params)

  @recurring %{
    "type" => "recurring",
    "rrule" => "FREQ=WEEKLY;BYDAY=TH",
    "time" => "19:00",
    "cost_template" => %{"items" => [%{"category" => "lapangan", "amount" => 350_000}]},
    "split_rule" => "equal"
  }

  test "a host creates a recurring event and gets no session", ctx do
    created = create(ctx.conn, ctx.host, ctx.group, @recurring)
    body = json_response(created, 201)
    Contract.check!("event.recurring", created)

    assert %{"event_id" => id, "session_id" => nil, "event" => event} = body
    assert event["rrule"] == "FREQ=WEEKLY;BYDAY=TH;BYHOUR=19;BYMINUTE=0"
    assert Repo.get!(Event, id).group_id == ctx.group.id
    assert Repo.aggregate(Session, :count) == 0
  end

  test "a host creates a one-off event and gets its draft session", ctx do
    params = %{
      "type" => "one_off",
      "starts_at" => "2026-10-08T19:00:00+07:00",
      "cost_template" => @recurring["cost_template"]
    }

    created = create(ctx.conn, ctx.host, ctx.group, params)
    assert %{"event_id" => event_id, "session_id" => session_id} = json_response(created, 201)
    Contract.check!("event.one_off", created)

    assert %Session{status: "draft", event_id: ^event_id, starts_at: ~U[2026-10-08 12:00:00Z]} =
             Repo.get!(Session, session_id)
  end

  test "an unsupported rrule is a 422 saying which part", ctx do
    params = Map.put(@recurring, "rrule", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TH")

    invalid = create(ctx.conn, ctx.host, ctx.group, params)

    assert %{"error" => "invalid_event", "details" => %{"rrule" => [message]}} =
             json_response(invalid, 422)

    Contract.check!("errors/invalid_event", invalid)

    assert message =~ "INTERVAL"
    assert Repo.aggregate(Event, :count) == 0
  end

  test "only hosts of the group may create events", ctx do
    forbidden = create(ctx.conn, ctx.plain, ctx.group, @recurring)
    assert %{"error" => "forbidden"} = json_response(forbidden, 403)
    Contract.check!("errors/forbidden", forbidden)

    # A host of another group learns nothing about this group.
    assert %{"error" => "not_found"} =
             create(ctx.conn, ctx.outsider, ctx.group, @recurring) |> json_response(404)

    assert %{"error" => "unauthenticated"} =
             ctx.conn
             |> post(~p"/api/groups/#{ctx.group.id}/events", @recurring)
             |> json_response(401)

    assert Repo.aggregate(Event, :count) == 0
  end

  test "a cost template naming a member of another group is refused", ctx do
    stranger = member_fixture(ctx.other, role: "member")

    params =
      Map.put(@recurring, "cost_template", %{
        "items" => [
          %{"category" => "lapangan", "amount" => 1000, "paid_by_member_id" => stranger.id}
        ]
      })

    assert %{"details" => %{"cost_template" => [_]}} =
             create(ctx.conn, ctx.host, ctx.group, params) |> json_response(422)
  end
end
