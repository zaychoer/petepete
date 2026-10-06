defmodule PetepeteWeb.AdminMetricsController do
  @moduledoc "The beta dashboard (`GET /api/admin/metrics`), behind `Plugs.MetricsToken`."
  use PetepeteWeb, :controller

  alias Petepete.Metrics.Report

  def show(conn, _params), do: json(conn, Report.build())
end
