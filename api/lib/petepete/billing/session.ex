defmodule Petepete.Billing.Session do
  @moduledoc """
  One occurrence of an event on a date. Status is draft/issued/cancelled; "settled"
  is derived from bills, never stored. Unique per `(event_id, starts_at)` unless cancelled.
  """
  use Ecto.Schema

  schema "sessions" do
    belongs_to :event, Petepete.Sessions.Event
    belongs_to :group, Petepete.Groups.Group
    field :starts_at, :utc_datetime
    field :status, :string, default: "draft"
    belongs_to :issue_txn, Petepete.Ledger.Txn

    timestamps(type: :utc_datetime)
  end
end
