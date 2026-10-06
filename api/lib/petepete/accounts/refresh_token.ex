defmodule Petepete.Accounts.RefreshToken do
  @moduledoc """
  A hashed refresh token, rotated on every refresh.

  Tokens issued from one login share a `family_id`; presenting a revoked token
  revokes the whole family.
  """
  use Ecto.Schema

  schema "refresh_tokens" do
    belongs_to :user, Petepete.Accounts.User
    field :family_id, Ecto.UUID
    field :token_hash, :binary
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
