defmodule PetepeteWeb.EventController do
  @moduledoc """
  Creating events (`POST /api/groups/:group_id/events`), host only. A template cost item
  without `paid_by_member_id` is paid by the creating host.
  """
  use PetepeteWeb, :controller

  alias Petepete.Sessions
  alias Petepete.Sessions.Event
  alias PetepeteWeb.{FallbackController, FieldErrors}

  plug PetepeteWeb.Plugs.GroupAccess, role: :host

  def create(conn, params) do
    case Sessions.create_event(conn.assigns.member, params) do
      {:ok, %{event: event, session: session}} ->
        conn
        |> put_status(:created)
        |> json(%{
          event_id: event.id,
          session_id: session && session.id,
          event: event_json(event)
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        FallbackController.respond(conn, 422, "invalid_event", %{
          details: FieldErrors.changeset_errors(changeset)
        })
    end
  end

  defp event_json(%Event{} = event) do
    Map.take(event, [
      :id,
      :group_id,
      :name,
      :type,
      :rrule,
      :starts_at,
      :cost_template,
      :split_rule,
      :active
    ])
  end
end
