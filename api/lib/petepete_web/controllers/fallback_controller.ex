defmodule PetepeteWeb.FallbackController do
  @moduledoc """
  Renders context errors as JSON: 404 `not_found`, 403 `forbidden`, 409 with the code of a
  `{:conflict, code}`, and 422 `invalid` with per-field messages for a changeset.
  """
  use PetepeteWeb, :controller

  def call(conn, {:error, :not_found}), do: respond(conn, 404, "not_found")
  def call(conn, {:error, :forbidden}), do: respond(conn, 403, "forbidden")
  def call(conn, {:error, {:conflict, code}}), do: respond(conn, 409, Atom.to_string(code))

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    fields =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn |> put_status(422) |> json(%{error: "invalid", fields: fields})
  end

  @doc false
  def respond(conn, status, error) do
    conn |> put_status(status) |> json(%{error: error})
  end
end
