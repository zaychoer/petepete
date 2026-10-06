defmodule PetepeteWeb.FallbackController do
  @moduledoc """
  Renders command errors as JSON: 404 `not_found`, 403 `forbidden`, 409 with the code of a
  `{:conflict, code}`, 409 `session_not_editable` (with the session `status`) and 422
  `invalid` with per-field messages under both `errors` and `fields`.
  """
  use PetepeteWeb, :controller

  def call(conn, {:error, :not_found}), do: respond(conn, 404, "not_found")
  def call(conn, {:error, :forbidden}), do: respond(conn, 403, "forbidden")

  def call(conn, {:error, {:conflict, :session_not_issued}}) do
    conn
    |> put_status(409)
    |> json(%{error: "session_not_issued", message: "Sesi ini belum ditagih."})
  end

  def call(conn, {:error, {:conflict, code}}), do: respond(conn, 409, Atom.to_string(code))

  def call(conn, {:error, {:session_not_editable, status}}) do
    conn
    |> put_status(409)
    |> json(%{
      error: "session_not_editable",
      status: status,
      status_label: PetepeteWeb.Labels.session(status),
      message: "Sesi ini sudah ditagih, jadi nggak bisa diubah lagi. Muat ulang dulu ya."
    })
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn |> put_status(422) |> json(%{error: "invalid", errors: errors, fields: errors})
  end

  @doc false
  def respond(conn, status, error) do
    conn |> put_status(status) |> json(%{error: error})
  end
end
