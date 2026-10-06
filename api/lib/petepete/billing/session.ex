defmodule Petepete.Billing.Session do
  @moduledoc """
  One occurrence of an event on a date. Status is draft/issued/cancelled; "settled"
  is derived from bills, never stored. Unique per `(event_id, starts_at)` unless cancelled.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Petepete.Sessions.Event

  schema "sessions" do
    belongs_to :event, Petepete.Sessions.Event
    belongs_to :group, Petepete.Groups.Group
    field :starts_at, :utc_datetime
    field :status, :string, default: "draft"
    belongs_to :issue_txn, Petepete.Ledger.Txn

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a new session of `event`. `event_id` and `group_id` come from the event
  (never from `attrs`); only `starts_at` is cast. The status is always draft; only
  `Petepete.Billing.Transitions` changes it afterwards.
  """
  def create_changeset(%Event{} = event, attrs) do
    %__MODULE__{event_id: event.id, group_id: event.group_id}
    |> cast(attrs, [:starts_at])
    |> validate_required([:starts_at])
    |> assoc_constraint(:event)
    |> assoc_constraint(:group)
    |> unique_constraint([:event_id, :starts_at], message: "already has a session at this time")
  end
end
