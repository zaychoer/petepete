defmodule Petepete.Sessions.SessionSchedulerTest do
  use Petepete.DataCase, async: true
  use Oban.Testing, repo: Petepete.Repo

  @moduletag :capture_log

  import Petepete.Fixtures, only: [group_fixture: 0, member_fixture: 2]

  alias Petepete.{Clock, Sessions}
  alias Petepete.Billing.Session
  alias Petepete.Sessions.{Event, SessionScheduler}

  setup do
    group = group_fixture()

    {:ok, %{event: event}} =
      Sessions.create_event(member_fixture(group, role: "host"), %{
        "type" => "recurring",
        "rrule" => "FREQ=WEEKLY;BYDAY=TH",
        "time" => "19:00"
      })

    # Monday 00:05 WIB.
    Clock.freeze(~U[2026-10-04 17:05:00Z])
    %{event: event}
  end

  test "creates the draft and a second run the same day creates nothing", %{event: event} do
    assert :ok = perform_job(SessionScheduler, %{})
    assert :ok = perform_job(SessionScheduler, %{})

    assert [%Session{status: "draft", starts_at: ~U[2026-10-08 12:00:00Z]}] =
             Repo.all(from s in Session, where: s.event_id == ^event.id)
  end

  test "reports an error when a session could not be created, so Oban retries", %{event: event} do
    Repo.update_all(from(e in Event, where: e.id == ^event.id), set: [rrule: "garbage"])

    assert {:error, _} = perform_job(SessionScheduler, %{})
  end

  test "is scheduled daily at 00:05 WIB, which cron (UTC) writes as 17:05" do
    {Oban.Plugins.Cron, opts} =
      :petepete |> Application.fetch_env!(Oban) |> Keyword.fetch!(:plugins) |> List.first()

    assert [{expression, SessionScheduler}] = Keyword.fetch!(opts, :crontab)
    parsed = Oban.Cron.Expression.parse!(expression)

    assert Oban.Cron.Expression.now?(parsed, ~U[2026-10-05 17:05:00Z])
    refute Oban.Cron.Expression.now?(parsed, ~U[2026-10-05 00:05:00Z])
    assert Petepete.Wib.to_utc(~D[2026-10-06], ~T[00:05:00]) == ~U[2026-10-05 17:05:00Z]
  end
end
