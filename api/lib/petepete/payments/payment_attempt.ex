defmodule Petepete.Payments.PaymentAttempt do
  @moduledoc "One request to pay a bill through the gateway; `external_id` is `<bill_id>-<seq>`."
  use Ecto.Schema

  schema "payment_attempts" do
    belongs_to :bill, Petepete.Billing.Bill
    field :seq, :integer
    field :external_id, :string
    field :provider, :string
    field :method, :string
    field :provider_ref, :string
    field :amount_due, :integer
    field :fee, :integer
    field :gross_amount, :integer
    field :paid_amount, :integer
    field :status, :string, default: "pending"
    field :action, :map
    field :expires_at, :utc_datetime
    field :retry_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
