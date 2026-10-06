defmodule Petepete.Groups.Member do
  @moduledoc """
  Anyone on a group's roster (table `group_members`), with or without an account.
  `default_weight` is integer per mil: 1000 = 1x.
  """
  use Ecto.Schema

  schema "group_members" do
    belongs_to :group, Petepete.Groups.Group
    belongs_to :user, Petepete.Accounts.User
    belongs_to :claim_user, Petepete.Accounts.User
    field :display_name, :string
    field :phone, :string
    field :role, :string
    field :default_weight, :integer, default: 1000

    timestamps(type: :utc_datetime)
  end
end
