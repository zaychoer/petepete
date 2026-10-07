defmodule Petepete.Billing.Bill do
  @moduledoc """
  One member's share of a session. Status: unpaid, paid, void, needs_review.
  At most one non-void bill per `(session_id, member_id)`.
  """
  use Ecto.Schema

  schema "bills" do
    belongs_to :session, Petepete.Billing.Session
    belongs_to :member, Petepete.Groups.Member
    field :share, :integer
    field :credit_applied, :integer, default: 0
    field :amount_due, :integer
    field :status, :string, default: "unpaid"
    field :paid_via, :string
    belongs_to :paid_txn, Petepete.Ledger.Txn
    field :paid_at, :utc_datetime
    field :pay_token, :string
    field :token_expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
