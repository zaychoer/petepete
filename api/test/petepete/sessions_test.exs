defmodule Petepete.SessionsTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures, only: [group_fixture: 0, member_fixture: 1, member_fixture: 2]

  alias Petepete.Billing
  alias Petepete.Billing.{CostItem, CostItemMember, Participant, Session}
  alias Petepete.Groups.Member
  alias Petepete.Sessions
  alias Petepete.Sessions.Event

  defp thursday_template(member) do
    %{
      "items" => [
        %{"category" => "lapangan", "amount" => 350_000},
        %{
          "category" => "minum",
          "label" => "Air",
          "amount" => 60_000,
          "scope" => "subset",
          "member_ids" => [member.id]
        }
      ]
    }
  end

  setup do
    group = group_fixture()
    a = member_fixture(group)
    b = member_fixture(group)
    guest = member_fixture(group, role: "guest")
    member_fixture(group, role: "host")
    %{group: group, a: a, b: b, guest: guest}
  end

  # The host who creates the event is the group's host member.
  defp create_event(group, params),
    do: Sessions.create_event(Repo.get_by!(Member, group_id: group.id, role: "host"), params)

  defp recurring!(group, attrs \\ %{}) do
    params =
      Map.merge(
        %{
          "type" => "recurring",
          "rrule" => "FREQ=WEEKLY;BYDAY=TH",
          "time" => "19:00",
          "cost_template" => %{"items" => [%{"category" => "lapangan", "amount" => 350_000}]}
        },
        attrs
      )

    {:ok, %{event: event}} = create_event(group, params)
    event
  end

  defp sessions_of(event), do: Repo.all(from s in Session, where: s.event_id == ^event.id)

  describe "create_event/2" do
    test "a recurring event stores the canonical rrule with its WIB time and creates no session",
         %{group: group} do
      assert {:ok, %{event: event, session: nil}} =
               create_event(group, %{
                 "type" => "recurring",
                 "rrule" => "FREQ=WEEKLY;BYDAY=TH",
                 "time" => "19:00",
                 "split_rule" => "equal"
               })

      assert event.rrule == "FREQ=WEEKLY;BYDAY=TH;BYHOUR=19;BYMINUTE=0"
      assert event.starts_at == nil
      assert event.name == group.name
      assert event.active
      assert sessions_of(event) == []
    end

    test "a one-off event gets its draft session at once, with the template's cost items",
         %{group: group, a: a} do
      template = %{
        "items" => [
          %{"category" => "lapangan", "amount" => 100_000, "paid_by_member_id" => a.id},
          %{
            "category" => "minum",
            "amount" => 20_000,
            "scope" => "subset",
            "member_ids" => [a.id]
          }
        ]
      }

      assert {:ok, %{event: event, session: session}} =
               create_event(group, %{
                 "type" => "one_off",
                 "name" => "Turnamen",
                 "starts_at" => "2026-10-08T19:00:00+07:00",
                 "cost_template" => template
               })

      assert session.status == "draft"
      assert session.event_id == event.id
      assert session.starts_at == ~U[2026-10-08 12:00:00Z]
      assert event.starts_at == ~U[2026-10-08 12:00:00Z]
      assert event.name == "Turnamen"

      items = Repo.all(from c in CostItem, where: c.session_id == ^session.id, order_by: c.id)

      assert [{"lapangan", 100_000, "all", paid_by}, {"minum", 20_000, "subset", default_payer}] =
               Enum.map(items, &{&1.category, &1.amount, &1.scope, &1.paid_by_member_id})

      assert paid_by == a.id
      assert default_payer == Repo.get_by!(Member, group_id: group.id, role: "host").id
      assert Repo.all(from m in CostItemMember, select: m.member_id) == [a.id]
    end

    test "an invalid event writes nothing and names the offending fields", %{group: group} do
      other = group_fixture()
      stranger = member_fixture(other)

      cases = [
        {%{"type" => "recurring", "rrule" => "FREQ=DAILY;BYDAY=TH", "time" => "19:00"}, :rrule},
        {%{"type" => "recurring", "rrule" => "FREQ=WEEKLY;BYDAY=TH"}, :time},
        {%{"type" => "recurring", "rrule" => "FREQ=WEEKLY;BYDAY=TH;BYHOUR=19", "time" => "20:00"},
         :time},
        {%{
           "type" => "recurring",
           "rrule" => "FREQ=WEEKLY;BYDAY=TH",
           "time" => "19:00",
           "starts_at" => "2026-10-08T19:00:00+07:00"
         }, :starts_at},
        {%{"type" => "one_off"}, :starts_at},
        {%{"type" => "one_off", "starts_at" => "2026-10-08T19:00:00"}, :starts_at},
        {%{
           "type" => "one_off",
           "starts_at" => "2026-10-08T12:00:00Z",
           "rrule" => "FREQ=WEEKLY;BYDAY=TH"
         }, :rrule},
        {%{"type" => "weekly"}, :type},
        {%{
           "type" => "one_off",
           "starts_at" => "2026-10-08T12:00:00Z",
           "cost_template" => %{"items" => [%{"category" => "lapangan", "amount" => 1.5}]}
         }, :cost_template},
        {%{
           "type" => "one_off",
           "starts_at" => "2026-10-08T12:00:00Z",
           "cost_template" => %{
             "items" => [%{"category" => "x", "amount" => 5, "paid_by_member_id" => stranger.id}]
           }
         }, :cost_template}
      ]

      for {params, field} <- cases do
        assert {:error, changeset} = create_event(group, params)
        assert Map.has_key?(errors_on(changeset), field), "#{inspect(params)}"
      end

      assert Repo.aggregate(Event, :count) == 0
      assert Repo.aggregate(Session, :count) == 0
    end
  end

  describe "generate_upcoming/1" do
    # Monday 2026-10-05 00:05 WIB, the moment the cron job runs.
    @monday_run ~U[2026-10-04 17:05:00Z]

    test "creates a draft H-3 ahead, and not earlier", %{group: group} do
      event = recurring!(group)

      # Sunday 00:05 WIB: Thursday is 4 days away.
      assert %{created: 0} = Sessions.generate_upcoming(~U[2026-10-03 17:05:00Z])
      assert sessions_of(event) == []

      assert %{created: 1, existing: 0, failed: 0} = Sessions.generate_upcoming(@monday_run)
      assert [%Session{status: "draft", group_id: gid} = session] = sessions_of(event)
      assert gid == group.id
      assert session.starts_at == ~U[2026-10-08 12:00:00Z]
    end

    test "run twice for the same day creates no duplicates of sessions or cost items",
         %{group: group, a: a} do
      event = recurring!(group, %{"cost_template" => thursday_template(a)})

      assert %{created: 1} = Sessions.generate_upcoming(@monday_run)
      assert %{created: 0, existing: 1, failed: 0} = Sessions.generate_upcoming(@monday_run)

      assert %{created: 0, existing: 1} =
               Sessions.generate_upcoming(DateTime.add(@monday_run, 3600))

      assert [session] = sessions_of(event)
      assert Repo.aggregate(from(c in CostItem, where: c.session_id == ^session.id), :count) == 2
    end

    test "copies the template's costs: label, amount, scope and subset members", %{
      group: group,
      a: a
    } do
      event = recurring!(group, %{"cost_template" => thursday_template(a)})
      Sessions.generate_upcoming(@monday_run)
      [session] = sessions_of(event)

      items = Repo.all(from c in CostItem, where: c.session_id == ^session.id, order_by: c.id)

      assert Enum.map(items, &{&1.category, &1.label, &1.amount, &1.scope}) == [
               {"lapangan", nil, 350_000, "all"},
               {"minum", "Air", 60_000, "subset"}
             ]

      assert Repo.all(from m in CostItemMember, select: m.member_id) == [a.id]
    end

    test "copies attendance, weights and guests from the previous session that had participants",
         %{group: group, a: a, b: b, guest: guest} do
      event = recurring!(group)

      last_week = session_for(event, ~U[2026-10-01 12:00:00Z])
      participant(last_week, a, true, 1200)
      participant(last_week, b, false, 1000)
      participant(last_week, guest, true, 500)

      # Later than last week but empty or cancelled: not a source.
      session_for(event, ~U[2026-10-04 12:00:00Z])
      cancelled = session_for(event, ~U[2026-10-03 12:00:00Z], status: "cancelled")
      participant(cancelled, b, true, 2000)

      assert %{created: 1} = Sessions.generate_upcoming(@monday_run)
      new = Repo.get_by!(Session, event_id: event.id, starts_at: ~U[2026-10-08 12:00:00Z])

      copied =
        Repo.all(from p in Participant, where: p.session_id == ^new.id, order_by: p.member_id)
        |> Enum.map(&{&1.member_id, &1.attended, &1.weight})

      assert copied == Enum.sort([{a.id, true, 1200}, {b.id, false, 1000}, {guest.id, true, 500}])
    end

    test "WIB, not UTC, decides the date: a Friday 06:30 WIB event is Thursday 23:30 UTC",
         %{group: group} do
      event = recurring!(group, %{"rrule" => "FREQ=WEEKLY;BYDAY=FR", "time" => "06:30"})

      # Monday 23:55 WIB (16:55 UTC): Friday is 4 days out.
      assert %{created: 0} = Sessions.generate_upcoming(~U[2026-10-05 16:55:00Z])

      # Tuesday 00:05 WIB is still Monday 17:05 UTC.
      assert %{created: 1} = Sessions.generate_upcoming(~U[2026-10-05 17:05:00Z])
      assert [%Session{starts_at: ~U[2026-10-08 23:30:00Z]}] = sessions_of(event)

      assert %{created: 0, existing: 1} = Sessions.generate_upcoming(~U[2026-10-05 17:05:00Z])
    end

    test "an occurrence missed by earlier runs is created once it is within 3 days",
         %{group: group} do
      event = recurring!(group)

      assert %{created: 1} = Sessions.generate_upcoming(~U[2026-10-06 17:05:00Z])
      assert [%Session{starts_at: ~U[2026-10-08 12:00:00Z]}] = sessions_of(event)
    end

    test "a cancelled draft is not brought back by the next run", %{group: group} do
      event = recurring!(group)
      Sessions.generate_upcoming(@monday_run)
      [session] = sessions_of(event)
      {:ok, _} = Billing.cancel_session(session.id)

      assert %{created: 0, existing: 1} = Sessions.generate_upcoming(@monday_run)
      assert [%Session{status: "cancelled"}] = sessions_of(event)
    end

    test "inactive and one-off events are left alone", %{group: group} do
      inactive = recurring!(group)
      Repo.update_all(from(e in Event, where: e.id == ^inactive.id), set: [active: false])

      {:ok, _} =
        create_event(group, %{
          "type" => "one_off",
          "starts_at" => "2026-10-08T12:00:00Z"
        })

      assert %{created: 0, existing: 0, failed: 0} = Sessions.generate_upcoming(@monday_run)
      assert Repo.aggregate(Session, :count) == 1
    end

    @tag :capture_log
    test "an event with an unreadable rrule is counted as failed and does not block the others",
         %{group: group} do
      broken = recurring!(group)
      Repo.update_all(from(e in Event, where: e.id == ^broken.id), set: [rrule: "garbage"])
      healthy = recurring!(group)

      assert %{created: 1, failed: 1} = Sessions.generate_upcoming(@monday_run)
      assert [%Session{}] = sessions_of(healthy)
      assert sessions_of(broken) == []
    end
  end

  defp session_for(event, starts_at, attrs \\ []) do
    Repo.insert!(
      struct(
        %Session{event_id: event.id, group_id: event.group_id, starts_at: starts_at},
        attrs
      )
    )
  end

  defp participant(session, member, attended, weight) do
    Repo.insert!(%Participant{
      session_id: session.id,
      member_id: member.id,
      attended: attended,
      weight: weight
    })
  end
end
