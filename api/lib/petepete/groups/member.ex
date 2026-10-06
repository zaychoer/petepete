defmodule Petepete.Groups.Member do
  @moduledoc """
  Anyone on a group's roster (table `group_members`), with or without an account.
  `default_weight` is integer per mil: 1000 = 1x.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Petepete.Accounts

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

  @doc """
  Casts a roster entry's `display_name` (required) and `phone` (optional, normalised to 62…).
  The caller sets group, role and account link on the struct.
  """
  def roster_changeset(member, attrs) do
    member
    |> cast(attrs, [:display_name, :phone])
    |> update_change(:display_name, &String.trim/1)
    |> validate_required([:display_name])
    |> validate_length(:display_name, max: 60)
    |> normalize_phone()
    |> unique_constraint(:user_id, name: :group_members_group_id_user_id_index)
  end

  defp normalize_phone(changeset) do
    with raw when is_binary(raw) <- get_change(changeset, :phone),
         {:ok, phone} <- Accounts.normalize_phone(raw) do
      put_change(changeset, :phone, phone)
    else
      nil ->
        changeset

      {:error, :invalid_phone} ->
        add_error(changeset, :phone, "is invalid", validation: :invalid_phone)
    end
  end
end
