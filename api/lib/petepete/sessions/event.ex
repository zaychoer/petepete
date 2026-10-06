defmodule Petepete.Sessions.Event do
  @moduledoc "What a group does, regularly (`rrule`) or once (`starts_at`)."
  use Ecto.Schema

  schema "events" do
    belongs_to :group, Petepete.Groups.Group
    field :name, :string
    field :type, :string
    field :rrule, :string
    field :starts_at, :utc_datetime
    field :cost_template, :map, default: %{}
    field :split_rule, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end
end
