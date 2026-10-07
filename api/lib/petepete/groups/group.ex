defmodule Petepete.Groups.Group do
  @moduledoc "A recurring sports group with one shared set of books."
  use Ecto.Schema

  import Ecto.Changeset

  alias Petepete.Groups.Templates

  schema "groups" do
    field :name, :string
    field :template, :string
    field :rounding_unit, :integer, default: 1000
    field :invite_token, :string

    has_many :members, Petepete.Groups.Member

    timestamps(type: :utc_datetime)
  end

  @doc "A new group from the host's `name` and `template`, with a fresh invite token."
  def create_changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :template])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :template])
    |> validate_length(:name, max: 80)
    |> validate_inclusion(:template, Templates.names())
    |> put_change(:invite_token, new_invite_token())
    |> unique_constraint(:invite_token)
  end

  @doc "A url-safe invite token with 128 bits of randomness."
  @spec new_invite_token() :: String.t()
  def new_invite_token, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
