defmodule PetepeteWeb.MemberController do
  @moduledoc "Claiming a roster entry without an account, and the host's decision on the claim."
  use PetepeteWeb, :controller

  alias Petepete.Groups

  action_fallback PetepeteWeb.FallbackController

  def claim(conn, %{"id" => id}), do: decide(conn, id, &Groups.claim/2)
  def approve(conn, %{"id" => id}), do: decide(conn, id, &Groups.approve_claim/2)
  def reject(conn, %{"id" => id}), do: decide(conn, id, &Groups.reject_claim/2)

  defp decide(conn, id, fun) do
    case Integer.parse(id) do
      {member_id, ""} when member_id in 1..9_223_372_036_854_775_807 ->
        with {:ok, _member} <- fun.(conn.assigns.current_scope, member_id),
             do: json(conn, %{ok: true})

      _ ->
        {:error, :not_found}
    end
  end
end
