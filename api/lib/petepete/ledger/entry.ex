defmodule Petepete.Ledger.Entry do
  @moduledoc "One signed rupiah entry against a member account or the group's kas."
  use Ecto.Schema

  schema "ledger_entries" do
    belongs_to :txn, Petepete.Ledger.Txn
    belongs_to :group, Petepete.Groups.Group
    field :account_type, :string
    belongs_to :member, Petepete.Groups.Member
    field :amount, :integer
  end
end
