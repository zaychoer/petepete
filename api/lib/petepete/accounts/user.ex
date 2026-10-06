defmodule Petepete.Accounts.User do
  @moduledoc "A login. `phone` is in 62… format; anonymised on account deletion."
  use Ecto.Schema

  schema "users" do
    field :phone, :string
    field :display_name, :string
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
