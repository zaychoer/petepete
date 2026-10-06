defmodule Petepete.Groups.Group do
  @moduledoc "A recurring sports group with one shared set of books."
  use Ecto.Schema

  schema "groups" do
    field :name, :string
    field :template, :string
    field :rounding_unit, :integer, default: 1000
    field :invite_token, :string

    has_many :members, Petepete.Groups.Member

    timestamps(type: :utc_datetime)
  end
end
