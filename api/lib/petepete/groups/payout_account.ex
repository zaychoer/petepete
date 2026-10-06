defmodule Petepete.Groups.PayoutAccount do
  @moduledoc "The gateway account that receives a group's online payments; owned by a member."
  use Ecto.Schema

  schema "payout_accounts" do
    belongs_to :group, Petepete.Groups.Group
    belongs_to :owner_member, Petepete.Groups.Member
    field :provider, :string
    field :provider_account_id, :string
    field :status, :string, default: "pending_kyc"
    field :bank_name, :string
    field :account_last4, :string
    field :idempotency_key, :string

    timestamps(type: :utc_datetime)
  end
end
