defmodule PetepeteWeb.FallbackController do
  @moduledoc """
  Renders command errors as JSON: 404 `not_found`, 403 `forbidden`, 409
  `session_not_editable` (with the session `status`) and 422 `invalid` (with `errors`
  per field).
  """
  use PetepeteWeb, :controller

  def call(conn, {:error, :not_found}), do: respond(conn, 404, "not_found")
  def call(conn, {:error, :forbidden}), do: respond(conn, 403, "forbidden")

  def call(conn, {:error, {:session_not_editable, status}}) do
    conn |> put_status(409) |> json(%{error: "session_not_editable", status: status})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn |> put_status(422) |> json(%{error: "invalid", errors: errors})
  end

  @doc false
  def respond(conn, status, error) do
    conn |> put_status(status) |> json(%{error: error})
  end
end
