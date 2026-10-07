defmodule Petepete.Ledger.Txn do
  @moduledoc "The balanced record of exactly one money event (one of eight `kind`s)."
  use Ecto.Schema

  schema "ledger_txns" do
    belongs_to :group, Petepete.Groups.Group
    field :kind, :string
    field :ref_type, :string
    field :ref_id, :integer
    field :actor_type, :string
    belongs_to :actor_user, Petepete.Accounts.User
    belongs_to :reverses_txn, __MODULE__
    field :reason, :string
    field :idempotency_key, :string

    has_many :entries, Petepete.Ledger.Entry, foreign_key: :txn_id

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
