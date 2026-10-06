defmodule PetepeteWeb.MeController do
  @moduledoc """
  The caller's own account: read it, set the display name (also the first-login
  name step), delete it (UU PDP). Acts on `current_scope.user` only, so no group
  authorization applies.
  """
  use PetepeteWeb, :controller

  alias Petepete.Accounts

  def show(conn, _params), do: json(conn, render_user(conn.assigns.current_scope.user))

  def update(conn, params) do
    case Accounts.update_profile(conn.assigns.current_scope, params["display_name"]) do
      {:ok, user} -> json(conn, render_user(user))
      {:error, :invalid_display_name} -> error(conn, 422, "invalid_display_name")
    end
  end

  def delete(conn, _params) do
    case Accounts.delete_account(conn.assigns.current_scope) do
      :ok -> json(conn, %{ok: true})
      {:error, :still_host} -> error(conn, 422, "still_host")
      {:error, :unauthenticated} -> error(conn, 401, "unauthenticated")
    end
  end

  defp render_user(user), do: %{id: user.id, phone: user.phone, display_name: user.display_name}

  defp error(conn, status, code), do: PetepeteWeb.FallbackController.respond(conn, status, code)
end
