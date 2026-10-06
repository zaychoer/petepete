defmodule PetepeteWeb.ShareController do
  @moduledoc """
  "Bagikan ke WA" texts of an issued session (`Petepete.Share`). The server only builds
  text; the host's device opens the wa.me link.

  `GET /api/sessions/:id/share/bills` and `/share/reminder` are host only (they carry pay
  tokens and members' `wa_number`) and are sent `Cache-Control: no-store`.
  `GET /api/sessions/:id/share/summary` is open to any member of the group: it has no
  tokens and no phone numbers. A session that is not issued is 409 `session_not_issued`.
  """
  use PetepeteWeb, :controller

  alias Petepete.Share
  alias PetepeteWeb.FallbackController

  plug PetepeteWeb.Plugs.SessionAccess, [role: :host] when action in [:bills, :reminder]
  plug PetepeteWeb.Plugs.SessionAccess, [role: :member] when action == :summary
  plug :no_store when action in [:bills, :reminder]

  def bills(conn, _params), do: respond(conn, Share.bills(conn.assigns.session_id))
  def reminder(conn, _params), do: respond(conn, Share.reminder(conn.assigns.session_id))
  def summary(conn, _params), do: respond(conn, Share.summary(conn.assigns.session_id))

  defp respond(conn, {:ok, body}), do: json(conn, body)
  defp respond(conn, {:error, _} = error), do: FallbackController.call(conn, error)

  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")
end
