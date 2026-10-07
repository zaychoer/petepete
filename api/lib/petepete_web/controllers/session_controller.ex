defmodule PetepeteWeb.SessionController do
  @moduledoc """
  A session's cost items and attendance for the host's screens. Every action resolves the
  session's group and authorizes inside `Petepete.Billing`; writes are host-only.

  `PUT /sessions/:id/costs/new` creates a cost item (201), `PUT /sessions/:id/costs/:cid`
  replaces an existing one (200).
  """
  use PetepeteWeb, :controller

  alias Petepete.Billing
  alias PetepeteWeb.FallbackController

  action_fallback FallbackController
  plug :put_view, json: PetepeteWeb.SessionJSON

  def show(conn, %{"id" => id}) do
    with {:ok, session_id} <- parse_id(id),
         {:ok, detail} <- Billing.get_session(conn.assigns.current_scope, session_id) do
      render(conn, :show, detail: detail)
    end
  end

  def put_cost(conn, %{"id" => id, "cid" => "new"}) do
    with {:ok, session_id} <- parse_id(id),
         {:ok, item} <-
           Billing.create_cost_item(conn.assigns.current_scope, session_id, conn.body_params) do
      conn |> put_status(:created) |> render(:cost_item, cost_item: item)
    end
  end

  def put_cost(conn, %{"id" => id, "cid" => cid}) do
    with {:ok, session_id} <- parse_id(id),
         {:ok, cost_item_id} <- parse_id(cid),
         {:ok, item} <-
           Billing.update_cost_item(
             conn.assigns.current_scope,
             session_id,
             cost_item_id,
             conn.body_params
           ) do
      render(conn, :cost_item, cost_item: item)
    end
  end

  def delete_cost(conn, %{"id" => id, "cid" => cid}) do
    with {:ok, session_id} <- parse_id(id),
         {:ok, cost_item_id} <- parse_id(cid),
         {:ok, _item} <-
           Billing.delete_cost_item(conn.assigns.current_scope, session_id, cost_item_id) do
      send_resp(conn, :no_content, "")
    end
  end

  def put_attendance(conn, %{"id" => id}) do
    with {:ok, session_id} <- parse_id(id),
         {:ok, participant} <-
           Billing.set_attendance(conn.assigns.current_scope, session_id, conn.body_params) do
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
