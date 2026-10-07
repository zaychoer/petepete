defmodule Petepete.Metrics.Event do
  @moduledoc """
  One MVP metric event (`metric_events`). Holds no phone number, name or user id: only the
  group, the session or bill it is about and, for durations, `value_ms`.
  """
  use Ecto.Schema

  schema "metric_events" do
    field :group_id, :integer
    field :name, :string
    field :session_id, :integer
    field :bill_id, :integer
    field :value_ms, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
