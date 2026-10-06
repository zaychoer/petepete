defmodule Mix.Tasks.Petepete.Metrics do
  @shortdoc "Prints the MVP metrics of the last 30 days"
  @moduledoc """
  Prints the same aggregates as `GET /api/admin/metrics` (`Petepete.Metrics.Report`):
  the whole window, then one line per day.

      mix petepete.metrics
  """
  use Mix.Task

  alias Petepete.Metrics.Report

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    report = Report.build()

    Mix.shell().info("MVP metrics #{report.from} .. #{report.to} (WIB days)\n")
    Mix.shell().info(summary("total", report.totals))
    Mix.shell().info("")

    for day <- report.days, do: Mix.shell().info(summary(Date.to_iso8601(day.date), day))
  end

  defp summary(label, row) do
    [
      String.pad_trailing(label, 10),
      "sessions=#{row.sessions_billed}",
      "build(med/p90)=#{duration(row.build_duration_ms)}",
      "bills_sent=#{row.bills_sent}",
      "to_paid(med/p90)=#{duration(row.time_to_paid_ms)}",
      "paid=#{row.paid_bills}",
      "no_install=#{row.paid_without_install} (#{pct(row.paid_without_install_pct)})"
    ]
    |> Enum.join("  ")
  end

  defp duration(%{median: nil}), do: "-"
  defp duration(%{median: median, p90: p90}), do: "#{seconds(median)}/#{seconds(p90)}"

  defp seconds(ms), do: "#{div(ms, 1000)}s"

  defp pct(nil), do: "-"
  defp pct(value), do: "#{value}%"
end
