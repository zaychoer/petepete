defmodule PetepeteWeb.SessionController do
  @moduledoc """
  A session's cost items and attendance for the host's screens. `SessionAccess` authorizes
  every action at the edge: any member of the session's group may read, writes are
  host-only (404 for an unknown session or a non-member, 403 for a non-host member).
  `Petepete.Billing` receives the host `Actor` and checks no role.

  `PUT /sessions/:id/costs/new` creates a cost item (201), `PUT /sessions/:id/costs/:cid`
  replaces an existing one (200).
  """
  use PetepeteWeb, :controller

  alias Petepete.Billing
  alias PetepeteWeb.FallbackController
  alias PetepeteWeb.Plugs.SessionAccess

  action_fallback FallbackController
  plug :put_view, json: PetepeteWeb.SessionJSON
  plug SessionAccess, [role: :member] when action == :show
  plug SessionAccess, [role: :host] when action in [:put_cost, :delete_cost, :put_attendance]

  def show(conn, _params) do
    with {:ok, detail} <- Billing.get_session(conn.assigns.session_id) do
      render(conn, :show, detail: detail)
    end
  end

  def put_cost(conn, %{"cid" => "new"}) do
    with {:ok, item} <-
           Billing.create_cost_item(conn.assigns.actor, conn.assigns.session_id, conn.body_params) do
      conn |> put_status(:created) |> render(:cost_item, cost_item: item)
    end
  end

  def put_cost(conn, %{"cid" => cid}) do
    with {:ok, cost_item_id} <- parse_id(cid),
         {:ok, item} <-
           Billing.update_cost_item(
             conn.assigns.actor,
             conn.assigns.session_id,
             cost_item_id,
             conn.body_params
           ) do
      render(conn, :cost_item, cost_item: item)
    end
  end

  def delete_cost(conn, %{"cid" => cid}) do
    with {:ok, cost_item_id} <- parse_id(cid),
         {:ok, _item} <-
           Billing.delete_cost_item(conn.assigns.actor, conn.assigns.session_id, cost_item_id) do
      send_resp(conn, :no_content, "")
    end
  end

  def put_attendance(conn, _params) do
    with {:ok, participant} <-
           Billing.set_attendance(conn.assigns.actor, conn.assigns.session_id, conn.body_params) do
      render(conn, :participant, participant: participant)
    end
  end

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end
end
