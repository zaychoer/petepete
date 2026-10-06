defmodule Petepete.Metrics.ReportTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.{Clock, Repo}
  alias Petepete.Metrics.{Event, Report}

  # 2026-10-06 10:00 WIB: the window is the WIB days 2026-09-07 .. 2026-10-06.
  @now ~U[2026-10-06 03:00:00Z]

  setup do
    Clock.freeze(@now)
    %{group: group_fixture()}
  end

  defp seed(group, rows) do
    rows =
      for {name, at, value} <- rows do
        %{group_id: group.id, name: name, value_ms: value, inserted_at: at}
      end

    Repo.insert_all(Event, rows)
  end

  test "aggregates the last 30 WIB days from seeded events", %{group: group} do
    seed(group, [
      # 2026-10-06 WIB, the 00:30 one coming from the previous UTC day.
      {"session_build_duration", ~U[2026-10-06 01:00:00Z], 60_000},
      {"session_build_duration", ~U[2026-10-06 02:00:00Z], 120_000},
      {"session_build_duration", ~U[2026-10-05 17:30:00Z], 180_000},
      {"bills_sent", ~U[2026-10-06 02:00:00Z], nil},
      {"bills_sent", ~U[2026-10-06 02:00:00Z], nil},
      {"bills_sent", ~U[2026-10-06 02:00:00Z], nil},
      {"time_to_paid", ~U[2026-10-06 02:30:00Z], 1_000},
      {"time_to_paid", ~U[2026-10-06 02:40:00Z], 3_000},
      {"paid_without_install", ~U[2026-10-06 02:40:00Z], nil},
      # 2026-10-03
      {"session_build_duration", ~U[2026-10-03 05:00:00Z], 240_000},
      {"time_to_paid", ~U[2026-10-03 05:00:00Z], 5_000},
      {"time_to_paid", ~U[2026-10-03 06:00:00Z], 9_000},
      # First instant of the window (2026-09-07 00:00 WIB) is in, the minute before is out.
      {"bills_sent", ~U[2026-09-06 17:00:00Z], nil},
      {"session_build_duration", ~U[2026-09-06 16:59:00Z], 999_999_999},
      {"time_to_paid", ~U[2026-09-06 16:59:00Z], 999_999_999}
    ])

    report = Report.build()

    assert report.from == ~D[2026-09-07]
    assert report.to == ~D[2026-10-06]

    assert report.totals == %{
             sessions_billed: 4,
             build_duration_ms: %{median: 150_000, p90: 222_000},
             bills_sent: 4,
             time_to_paid_ms: %{median: 4_000, p90: 7_800},
             paid_bills: 4,
             paid_without_install: 1,
             paid_without_install_pct: 25.0
           }

    assert length(report.days) == 30
    assert hd(report.days).date == ~D[2026-09-07]
    assert List.last(report.days).date == ~D[2026-10-06]
    day = fn date -> Enum.find(report.days, &(&1.date == date)) end

    assert day.(~D[2026-10-06]) == %{
             date: ~D[2026-10-06],
             sessions_billed: 3,
             build_duration_ms: %{median: 120_000, p90: 168_000},
             bills_sent: 3,
             time_to_paid_ms: %{median: 2_000, p90: 2_800},
             paid_bills: 2,
             paid_without_install: 1,
             paid_without_install_pct: 50.0
           }

    assert %{paid_without_install_pct: +0.0, time_to_paid_ms: %{median: 7_000, p90: 8_600}} =
             day.(~D[2026-10-03])

    assert day.(~D[2026-09-07]).bills_sent == 1

    assert day.(~D[2026-09-20]) == %{
             date: ~D[2026-09-20],
             sessions_billed: 0,
             build_duration_ms: %{median: nil, p90: nil},
             bills_sent: 0,
             time_to_paid_ms: %{median: nil, p90: nil},
             paid_bills: 0,
             paid_without_install: 0,
             paid_without_install_pct: nil
           }
  end

  test "an empty database gives an all-zero report" do
    report = Report.build()

    assert %{sessions_billed: 0, bills_sent: 0, paid_bills: 0, paid_without_install_pct: nil} =
             report.totals

    assert length(report.days) == 30
  end
end
