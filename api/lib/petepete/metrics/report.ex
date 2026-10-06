defmodule Petepete.Metrics.Report do
  @moduledoc """
  Aggregates of `metric_events` for the beta dashboard (PP-REL-02), computed in SQL over
  the last 30 WIB calendar days, today included. Served by `GET /api/admin/metrics` and
  printed by `mix petepete.metrics`.

  Per period (the whole window under `totals`, each day under `days`):

    * `sessions_billed`: sessions issued (`session_build_duration` events)
    * `build_duration_ms`: `median` and `p90` of those events' durations
    * `bills_sent`: bills created at issue
    * `time_to_paid_ms`: `median` and `p90` of issue to paid, for bills paid by gateway or cash
    * `paid_bills`: those bills (the `time_to_paid` events)
    * `paid_without_install`: bills paid through the gateway by a member without an account
    * `paid_without_install_pct`: `paid_without_install` as a percentage of `paid_bills`,
      one decimal; `nil` when nothing was paid

  Durations are whole milliseconds, `nil` when the period has no event. Days without
  events are present with zero counts.
  """

  alias Petepete.{Clock, Repo, Wib}

  @window_days 30

  @columns """
  count(*) FILTER (WHERE e.name = 'session_build_duration') AS sessions_billed,
  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY e.value_ms)
    FILTER (WHERE e.name = 'session_build_duration'))::bigint AS build_median_ms,
  round(percentile_cont(0.9) WITHIN GROUP (ORDER BY e.value_ms)
    FILTER (WHERE e.name = 'session_build_duration'))::bigint AS build_p90_ms,
  count(*) FILTER (WHERE e.name = 'bills_sent') AS bills_sent,
  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY e.value_ms)
    FILTER (WHERE e.name = 'time_to_paid'))::bigint AS paid_median_ms,
  round(percentile_cont(0.9) WITHIN GROUP (ORDER BY e.value_ms)
    FILTER (WHERE e.name = 'time_to_paid'))::bigint AS paid_p90_ms,
  count(*) FILTER (WHERE e.name = 'time_to_paid') AS paid_bills,
  count(*) FILTER (WHERE e.name = 'paid_without_install') AS paid_without_install,
  round(100.0 * count(*) FILTER (WHERE e.name = 'paid_without_install')
    / nullif(count(*) FILTER (WHERE e.name = 'time_to_paid'), 0), 1) AS paid_without_install_pct
  """

  # The event day is its WIB calendar date (inserted_at is stored as UTC).
  @windowed_events """
  (SELECT name, value_ms, (inserted_at + interval '7 hours')::date AS day
   FROM metric_events
   WHERE (inserted_at + interval '7 hours')::date BETWEEN $1::date AND $2::date)
  """

  @totals_sql "SELECT #{@columns} FROM #{@windowed_events} e"

  @days_sql """
  SELECT d.day, #{@columns}
  FROM (SELECT ($1::date + g)::date AS day FROM generate_series(0, $3::int) AS g) d
  LEFT JOIN #{@windowed_events} e ON e.day = d.day::date
  GROUP BY d.day
  ORDER BY d.day
  """

  @doc "The report for the 30 WIB days ending on today (`Petepete.Clock.now/0`)."
  @spec build() :: map()
  def build do
    to = Wib.date(Clock.now())
    from = Date.add(to, -(@window_days - 1))
    params = [from, to]

    [totals] = rows(@totals_sql, params)
    days = rows(@days_sql, params ++ [@window_days - 1])

    %{
      from: from,
      to: to,
      totals: format(totals),
      days: Enum.map(days, &(&1 |> format() |> Map.put(:date, &1.day)))
    }
  end

  defp rows(sql, params) do
    %{columns: columns, rows: rows} = Repo.query!(sql, params)

    Enum.map(rows, fn row ->
      columns |> Enum.zip(row) |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    end)
  end

  defp format(row) do
    %{
      sessions_billed: row.sessions_billed,
      build_duration_ms: %{median: row.build_median_ms, p90: row.build_p90_ms},
      bills_sent: row.bills_sent,
      time_to_paid_ms: %{median: row.paid_median_ms, p90: row.paid_p90_ms},
      paid_bills: row.paid_bills,
      paid_without_install: row.paid_without_install,
      paid_without_install_pct: pct(row.paid_without_install_pct)
    }
  end

  defp pct(nil), do: nil
  defp pct(%Decimal{} = decimal), do: Decimal.to_float(decimal)
end
