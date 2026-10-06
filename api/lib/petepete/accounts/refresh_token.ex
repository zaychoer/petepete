defmodule Petepete.Accounts.RefreshToken do
  @moduledoc "A hashed refresh token, rotated on every refresh."
  use Ecto.Schema

  schema "refresh_tokens" do
    belongs_to :user, Petepete.Accounts.User
    field :token_hash, :binary
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
