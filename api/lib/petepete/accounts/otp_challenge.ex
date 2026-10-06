defmodule Petepete.Accounts.OtpChallenge do
  @moduledoc "A pending OTP login attempt; phone and code are stored hashed only."
  use Ecto.Schema

  schema "otp_challenges" do
    field :phone_hash, :binary
    field :code_hash, :binary
    field :ip, :string
    field :attempts, :integer, default: 0
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
