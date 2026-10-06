defmodule PetepeteWeb.FallbackController do
  @moduledoc "Renders authorization errors as JSON: 404 `not_found`, 403 `forbidden`."
  use PetepeteWeb, :controller

  def call(conn, {:error, :not_found}), do: respond(conn, 404, "not_found")
  def call(conn, {:error, :forbidden}), do: respond(conn, 403, "forbidden")

  @doc false
  def respond(conn, status, error) do
    conn |> put_status(status) |> json(%{error: error})
  end
end
