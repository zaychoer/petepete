defmodule Petepete.Payments.Withdrawal do
  @moduledoc """
  One request by the payout account owner to move money from the gateway sub-account to
  the registered bank account. Status `submitted`: the gateway accepted it (`provider_ref`).
  `managed`: the sub-account has no payout API, the host finishes on the gateway dashboard
  at `managed_url`. Withdrawals never touch the Ledger (the money was already recorded as
  held by the host).
  """
  use Ecto.Schema

  schema "withdrawals" do
    belongs_to :group, Petepete.Groups.Group
    belongs_to :payout_account, Petepete.Groups.PayoutAccount
    field :amount, :integer
    field :status, :string
    field :provider_ref, :string
    field :managed_url, :string
    field :idempotency_key, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
