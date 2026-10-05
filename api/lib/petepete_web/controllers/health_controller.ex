defmodule PetepeteWeb.HealthController do
  use PetepeteWeb, :controller

  # Shallow on purpose: no database call, so a Postgres outage doesn't make Fly
  # restart healthy machines. Migrations (release_command) catch a bad DATABASE_URL.
  def show(conn, _params), do: json(conn, %{status: "ok"})
end
