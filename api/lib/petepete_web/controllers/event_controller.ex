defmodule PetepeteWeb.EventController do
  @moduledoc "Creating events (`POST /api/groups/:group_id/events`), host only."
  use PetepeteWeb, :controller

  alias Petepete.Sessions
  alias Petepete.Sessions.Event

  plug PetepeteWeb.Plugs.GroupAccess, role: :host

  def create(conn, params) do
    case Sessions.create_event(conn.assigns.member.group_id, params) do
      {:ok, %{event: event, session: session}} ->
        conn
        |> put_status(:created)
        |> json(%{
          event_id: event.id,
          session_id: session && session.id,
          event: event_json(event)
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_event", details: errors(changeset)})
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

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
