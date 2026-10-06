defmodule Petepete.Billing.Session do
  @moduledoc """
  One occurrence of an event on a date. Status is draft/issued/cancelled; "settled"
  is derived from bills, never stored. Unique per `(event_id, starts_at)` unless cancelled.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

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
  Changeset for a new session. The status is always draft; only
  `Petepete.Billing.Transitions` changes it afterwards.
  """
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [:event_id, :group_id, :starts_at])
    |> validate_required([:event_id, :group_id, :starts_at])
    |> validate_event_in_group()
    |> assoc_constraint(:event)
    |> assoc_constraint(:group)
    |> unique_constraint([:event_id, :starts_at], message: "already has a session at this time")
  end

  defp validate_event_in_group(changeset) do
    event_id = get_field(changeset, :event_id)
    group_id = get_field(changeset, :group_id)

    if changeset.valid? and
         not Petepete.Repo.exists?(
           from e in Event, where: e.id == ^event_id and e.group_id == ^group_id
         ) do
      add_error(changeset, :event_id, "does not belong to the group")
    else
      changeset
    end
  end
end
